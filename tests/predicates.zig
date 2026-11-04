const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const all = zrx.all;
const any = zrx.any;
const a = std.testing.allocator;
const io = std.testing.io;

const Probe = struct {
    trace: [16]u8 = undefined,
    len: usize = 0,
    accepted: usize = 0,
    last: i32 = 0,
    acquired: usize = 0,
    released: usize = 0,
    fn record(self: *Probe, byte: u8) void {
        self.trace[self.len] = byte;
        self.len += 1;
    }
};
const Lower = struct { value: i32 };
const Upper = struct { value: i32 };
fn acquire(p: *Probe, _: void) Upper {
    p.acquired += 1;
    return .{ .value = 6 };
}
fn release(p: *Probe, _: Upper) void {
    p.released += 1;
}
fn lower(p: *Probe, bound: Lower, value: i32) bool {
    p.record('L');
    return value >= bound.value;
}
fn upper(bound: Upper, p: *Probe, value: i32) bool {
    p.record('U');
    return value <= bound.value;
}
fn even(p: *Probe, value: i32) bool {
    p.record('E');
    return @mod(value, 2) == 0;
}
fn failed(p: *Probe, _: i32) error{PredicateFailed}!bool {
    p.record('F');
    return error.PredicateFailed;
}
fn accept(p: *Probe, value: i32) void {
    p.accepted += 1;
    p.last = value;
}
fn ignore(_: i32) void {}
fn recover(_: error{PredicateFailed}) i32 {
    return -99;
}

fn check(comptime predicate: anytype, value: i32, trace: []const u8, accepted: usize) !void {
    var p: Probe = .{};
    const flow = pipe(zrx.fromValue(value), .{ zrx.filter(predicate), zrx.forEach(accept) });
    try std.testing.expectEqual(@as(usize, 0), p.len); // Construction is cold.
    try zrx.run(.{ a, io, &p, Lower{ .value = 0 }, zrx.resource({}, acquire, release) }, .{flow});
    try std.testing.expectEqualStrings(trace, p.trace[0..p.len]);
    try std.testing.expectEqual(accepted, p.accepted);
    // Services remain reachable even for an item that skips their predicate.
    try std.testing.expectEqual(@as(usize, 1), p.acquired);
    try std.testing.expectEqual(@as(usize, 1), p.released);
}

test "all short circuits in order with independent injected prefixes" {
    const predicate = all(.{ lower, upper, even });
    try check(predicate, -1, "L", 0);
    try check(predicate, 0, "LUE", 1);
    try check(predicate, 3, "LUE", 0);
    try check(predicate, 10, "LU", 0);
}

test "nested any short circuits true and evaluates remaining false predicates" {
    const predicate = all(.{ lower, any(.{ even, upper }) });
    try check(predicate, -1, "L", 0);
    try check(predicate, 0, "LE", 1);
    try check(predicate, 3, "LEU", 1);
    try check(predicate, 9, "LEU", 0);
}

test "fallible predicates stop on first error and filter recovery remains explicit" {
    var p: Probe = .{};
    try zrx.run(.{ a, io, &p, Lower{ .value = 0 }, zrx.resource({}, acquire, release) }, .{
        pipe(zrx.fromValue(@as(i32, 1)), .{
            zrx.filter(all(.{ lower, failed, upper })),
            zrx.recover(recover),
            zrx.forEach(accept),
        }),
    });
    try std.testing.expectEqualStrings("LF", p.trace[0..p.len]);
    try std.testing.expectEqual(@as(i32, -99), p.last);
    try std.testing.expectEqual(@as(usize, 1), p.released);
    p = .{};
    try zrx.run(.{ a, io, &p, Lower{ .value = 0 } }, .{
        pipe(zrx.fromValue(@as(i32, 1)), .{ zrx.filter(any(.{ lower, failed })), zrx.forEach(accept) }),
    });
    try std.testing.expectEqualStrings("L", p.trace[0..p.len]);
    p = .{};
    try std.testing.expectError(error.PredicateFailed, zrx.run(.{ a, io, &p, Lower{ .value = 0 } }, .{
        pipe(zrx.fromValue(@as(i32, -1)), .{ zrx.filter(any(.{ lower, failed })), zrx.forEach(accept) }),
    }));
    try std.testing.expectEqualStrings("LF", p.trace[0..p.len]);
}

test "branch uses the same composition and services acquire once" {
    var p: Probe = .{};
    try zrx.run(.{ a, io, &p, Lower{ .value = 0 }, zrx.resource({}, acquire, release) }, .{
        pipe(zrx.fromValue(@as(i32, 3)), .{zrx.branch(.{
            zrx.when(all(.{ lower, any(.{ even, upper }) }), zrx.forEach(accept)),
            zrx.otherwise(zrx.forEach(ignore)),
        })}),
    });
    try std.testing.expectEqualStrings("LEU", p.trace[0..p.len]);
    try std.testing.expectEqual(@as(usize, 1), p.accepted);
    try std.testing.expectEqual(p.acquired, p.released);
}

const Separators = struct { comma: u8 = ',', space: u8 = ' ' };
fn comma(s: Separators, byte: u8) bool {
    return byte == s.comma;
}
fn space(s: Separators, byte: u8) bool {
    return byte == s.space;
}
const Frames = struct { count: usize = 0, letters: [2]u8 = undefined };
fn frame(result: *Frames, value: zrx.Chunk(u8, 4)) void {
    result.letters[result.count] = value.items[0];
    result.count += 1;
}
test "splitBy recognizes composed pure predicates instead of treating them as delimiters" {
    var frames: Frames = .{};
    try zrx.run(.{ a, io, Separators{}, &frames }, .{
        pipe(zrx.fromValue(@as([]const u8, "a, b")), .{
            zrx.splitBy(any(.{ comma, space }), .{ .max_items = 4, .empty = .skip }),
            zrx.forEach(frame),
        }),
    });
    try std.testing.expectEqual(@as(usize, 2), frames.count);
    try std.testing.expectEqualStrings("ab", &frames.letters);
}

test "composed finite filtering does not introduce concurrent workers" {
    var backend: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(0) });
    defer backend.deinit();
    var p: Probe = .{};
    try zrx.run(.{ a, backend.io(), &p, Lower{ .value = 0 } }, .{
        pipe(zrx.fromValue(@as(i32, 2)), .{ zrx.filter(all(lower)), zrx.forEach(accept) }),
    });
    try std.testing.expectEqual(@as(usize, 1), p.accepted);
}
