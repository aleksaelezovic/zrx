const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const tap = zrx.tap;
const tapWith = zrx.tapWith;
const filter = zrx.filter;

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u32 {
    return value + 1;
}

fn nonzero(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn ignore(_: u32) void {}

fn record(destination: *u32, value: u32) void {
    destination.* = value;
}

fn reject(reject_value: bool, _: u32) error{Rejected}!void {
    if (reject_value) return error.Rejected;
}

test "tap constructs without execution and forwards the same input pointer" {
    const State = struct {
        count: u32 = 0,
        fn visit(self: *@This()) void {
            self.count += 1;
        }
    };
    var state: State = .{};
    const stage = tap(State.visit);
    try std.testing.expectEqual(@as(u32, 0), state.count);
    const result = pipe(&state, .{stage});
    try std.testing.expect(result == &state);
    try std.testing.expectEqual(@as(u32, 1), state.count);
    _ = pipe(&state, .{stage});
    try std.testing.expectEqual(@as(u32, 2), state.count);
}

test "tap and tapWith use normal argument coercions and forward the coerced type" {
    const small: u8 = 3;
    const result = pipe(small, .{tap(ignore)});
    try std.testing.expectEqual(u32, @TypeOf(result));
    try std.testing.expectEqual(@as(u32, 3), result);
    var recorded: u32 = 0;
    const after = pipe(3, .{
        map(double),
        tapWith(&recorded, record),
        map(increment),
    });
    try std.testing.expectEqual(@as(u32, 6), recorded);
    try std.testing.expectEqual(@as(u32, 7), after);
}

test "ordinary pipe preserves effect errors as values and runs explicit recovery" {
    const Helpers = struct {
        fn recover(value: error{Rejected}!u32) u32 {
            return value catch 99;
        }
    };
    const failed = pipe(3, .{tapWith(true, reject)});
    try std.testing.expectEqual(error{Rejected}!u32, @TypeOf(failed));
    try std.testing.expectError(error.Rejected, failed);
    try std.testing.expectEqual(@as(u32, 99), pipe(3, .{
        tapWith(true, reject),
        map(Helpers.recover),
    }));
    try std.testing.expectEqual(@as(u32, 3), try pipe(3, .{tapWith(false, reject)}));
}

test "effects may use Zig inferred error sets" {
    const Helpers = struct {
        fn inferred(value: u32) !void {
            if (value == 0) return error.Inferred;
        }
    };
    try std.testing.expectError(error.Inferred, tryPipe(0, .{tap(Helpers.inferred)}));
    try std.testing.expectEqual(@as(u32, 3), try tryPipe(3, .{tap(Helpers.inferred)}));
}

test "tap can observe error values without unwrapping them" {
    const Data = error{Data}!u32;
    const Helpers = struct {
        fn observe(_: Data) void {}
        fn fallible(_: Data) error{Effect}!void {}
    };
    const value: Data = error.Data;
    try std.testing.expectError(error.Data, pipe(value, .{tap(Helpers.observe)}));
    const nested = pipe(value, .{tap(Helpers.fallible)});
    try std.testing.expectEqual(error{Effect}!Data, @TypeOf(nested));
    try std.testing.expectError(error.Data, try nested);
}

test "tryPipe includes initial and stage error sets and skips all effects on initial failure" {
    const initial: error{Initial}!u32 = error.Initial;
    var recorded: u32 = 0;
    const result = tryPipe(initial, .{
        map(nonzero),
        tapWith(false, reject),
        tapWith(&recorded, record),
    });
    try std.testing.expectEqual(error{ Initial, Zero, Rejected }!u32, @TypeOf(result));
    try std.testing.expectError(error.Initial, result);
    try std.testing.expectEqual(@as(u32, 0), recorded);
}

test "tryPipe stops after the first effect error without rolling back prior effects" {
    var before: u32 = 0;
    var after: u32 = 0;
    try std.testing.expectError(error.Rejected, tryPipe(7, .{
        tapWith(&before, record),
        tapWith(true, reject),
        tapWith(&after, record),
    }));
    try std.testing.expectEqual(@as(u32, 7), before);
    try std.testing.expectEqual(@as(u32, 0), after);
}

test "tapping a whole view does not consume its elements" {
    const Predicates = struct {
        var calls: usize = 0;
        fn even(value: u32) bool {
            calls += 1;
            return value % 2 == 0;
        }
    };
    Predicates.calls = 0;
    const values = [_]u32{ 1, 2, 3 };
    const view = pipe(&values, .{filter(Predicates.even)});
    const View = @TypeOf(view);
    const Observer = struct {
        fn observe(count: *usize, _: View) void {
            count.* += 1;
        }
    };
    var observations: usize = 0;
    const result = pipe(view, .{tapWith(&observations, Observer.observe)});
    try std.testing.expectEqual(@as(usize, 1), observations);
    try std.testing.expectEqual(@as(usize, 0), Predicates.calls);
    var iterator = result.iterator();
    try std.testing.expectEqual(@as(?u32, 2), iterator.next());
    try std.testing.expectEqual(@as(usize, 2), Predicates.calls);
}

fn writeNumber(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d}", .{value});
}

test "tapWith uses a standard fixed-buffer writer directly" {
    var storage: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try std.testing.expectEqual(@as(u32, 42), try tryPipe(42, .{tapWith(&writer, writeNumber)}));
    try std.testing.expectEqualStrings("42", writer.buffered());
    var short: [1]u8 = undefined;
    var failing: std.Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, tryPipe(42, .{tapWith(&failing, writeNumber)}));
}

test "tapWith accepts std.Io as an ordinary runtime handle" {
    const Helpers = struct {
        var received: ?std.Io = null;
        fn observe(io: std.Io, _: u32) void {
            received = io;
        }
    };
    Helpers.received = null;
    _ = pipe(3, .{tapWith(std.testing.io, Helpers.observe)});
    try std.testing.expect(Helpers.received.?.userdata == std.testing.io.userdata);
    try std.testing.expect(Helpers.received.?.vtable == std.testing.io.vtable);
}

test "resource cleanup remains with the caller on tryPipe failure" {
    const Helpers = struct {
        fn fail(_: []u8) error{Failed}!void {
            return error.Failed;
        }
    };
    const owned = try std.testing.allocator.alloc(u8, 4);
    defer std.testing.allocator.free(owned);
    try std.testing.expectError(error.Failed, tryPipe(owned, .{tap(Helpers.fail)}));
    owned[0] = 7;
    try std.testing.expectEqual(@as(u8, 7), owned[0]);
}
