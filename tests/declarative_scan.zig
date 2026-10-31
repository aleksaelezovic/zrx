const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const run = zrx.run;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const fromIterator = zrx.fromIterator;
const scan = zrx.scan;
const collectThen = zrx.collectThen;
const forEach = zrx.forEach;
const take = zrx.take;
const hold = zrx.hold;
const values = zrx.values;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Saved = struct {
    items: [16]u64 = undefined,
    len: usize = 0,

    fn save(self: *@This(), items: []const u64) void {
        @memcpy(self.items[0..items.len], items);
        self.len = items.len;
    }
    fn expect(self: *const @This(), items: []const u64) !void {
        try std.testing.expectEqualSlices(u64, items, self.items[0..self.len]);
    }
};

fn add(state: u64, item: u32) u64 {
    return state + item;
}

test "finite scan is cold, emits updates only, and starts fresh each run" {
    var saved: Saved = .{};
    const accumulated = pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{scan(@as(u64, 10), add)});
    const flow = pipe(&accumulated, .{collectThen(Saved.save)});
    try std.testing.expectEqual(@as(usize, 0), saved.len);
    for (0..2) |_| {
        try run(.{ allocator, io, &saved }, .{flow});
        try saved.expect(&.{ 11, 13, 16 });
    }
}

test "empty scan emits nothing and singleton emits its accumulated value" {
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved }, .{
        pipe(fromSlice(&[_]u32{}), .{ scan(@as(u64, 10), add), collectThen(Saved.save) }),
    });
    try saved.expect(&.{});
    try run(.{ allocator, io, &saved }, .{
        pipe(fromValue(@as(u32, 2)), .{ scan(@as(u64, 10), add), collectThen(Saved.save) }),
    });
    try saved.expect(&.{12});
}

const Scale = struct { factor: u32 };
fn scaled(scale: Scale, state: u64, item: u32) u64 {
    return state + item * scale.factor;
}

test "scan injects leading services while state and item remain ordinary data" {
    var saved: Saved = .{};
    const named = pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{scan(@as(u64, 0), scaled)});
    // u64/u32 bindings deliberately differ from the ordinary suffix values.
    try run(.{ allocator, io, &saved, Scale{ .factor = 3 }, @as(u64, 900), @as(u32, 800) }, .{
        pipe(&named, .{collectThen(Saved.save)}),
    });
    try saved.expect(&.{ 3, 9, 18 });
}

const Lifetime = struct { acquired: bool = false, released: bool = false };
fn acquire(lifetime: *Lifetime, factor: u32) Scale {
    lifetime.acquired = true;
    return .{ .factor = factor };
}
fn release(lifetime: *Lifetime, _: Scale) void {
    lifetime.released = true;
}
fn checkLifetime(lifetime: *Lifetime, item: u64) !void {
    try std.testing.expect(lifetime.acquired);
    try std.testing.expect(!lifetime.released);
    try std.testing.expectEqual(@as(u64, 6), item);
}

test "scan dependencies participate in managed acquisition and release" {
    var lifetime: Lifetime = .{};
    const scale = zrx.resource(@as(u32, 2), acquire, release);
    const flow = pipe(fromValue(@as(u32, 3)), .{
        scan(@as(u64, 0), scaled),
        forEach(checkLifetime),
    });
    try std.testing.expect(!lifetime.acquired);
    try run(.{ allocator, io, &lifetime, scale }, .{flow});
    try std.testing.expect(lifetime.released);
}

const Produced = struct { calls: usize = 0 };
fn produce(state: *Produced, output: *zrx.Emitter(u32)) !void {
    state.calls += 1;
    for ([_]u32{ 1, 2, 3, 4 }) |item| try output.push(item);
}
const Left = struct { saved: *Saved };
const Right = struct { saved: *Saved };
fn saveLeft(output: Left, items: []const u64) void {
    output.saved.save(items);
}
fn saveRight(output: Right, items: []const u64) void {
    output.saved.save(items);
}

test "shared recurrence retires a prefix without stopping its sibling" {
    var produced: Produced = .{};
    var left: Saved = .{};
    var right: Saved = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const accumulated = pipe(&source, .{scan(@as(u64, 0), add)});
    try run(.{ allocator, io, &produced, Left{ .saved = &left }, Right{ .saved = &right } }, .{
        pipe(&accumulated, .{ take(2), collectThen(saveLeft) }),
        pipe(&accumulated, .{collectThen(saveRight)}),
    });
    try std.testing.expectEqual(@as(usize, 1), produced.calls);
    try left.expect(&.{ 1, 3 });
    try right.expect(&.{ 1, 3, 6, 10 });
}

test "exclusive named scan adds no forwarding worker" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2), .async_limit = .nothing });
    defer backend.deinit();
    var produced: Produced = .{};
    var saved: Saved = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const accumulated = pipe(&source, .{scan(@as(u64, 0), add)});
    try run(.{ allocator, backend.io(), &produced, &saved }, .{
        pipe(&accumulated, .{collectThen(Saved.save)}),
    });
    try saved.expect(&.{ 1, 3, 6, 10 });
}

test "hold observes seed followed by scan snapshots" {
    var saved: Saved = .{};
    const accumulated = pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{scan(@as(u64, 10), add)});
    const current = pipe(&accumulated, .{hold(@as(u64, 10))});
    try run(.{ allocator, io, &saved }, .{
        pipe(values(&current), .{collectThen(Saved.save)}),
    });
    try saved.expect(&.{ 10, 11, 13, 16 });
}

const ErrorState = struct { value: error{Missing}!u32 };
fn replace(_: ErrorState, item: error{Missing}!u32) ErrorState {
    return .{ .value = item };
}
fn expectErrorData(items: []const ErrorState) !void {
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(u32, 1), try items[0].value);
    try std.testing.expectError(error.Missing, items[1].value);
    try std.testing.expectEqual(@as(u32, 2), try items[2].value);
}

test "error-valued elements and boxed error state remain data" {
    const input = [_]error{Missing}!u32{ 1, error.Missing, 2 };
    try run(.{ allocator, io }, .{
        pipe(fromSlice(&input), .{ scan(ErrorState{ .value = 0 }, replace), collectThen(expectErrorData) }),
    });
}

fn failingSource(output: *zrx.Emitter(u32)) !void {
    try output.push(1);
    return error.SourceFailed;
}
fn unexpected(_: []const u64) void {
    @panic("collection must be suppressed on source failure");
}

test "scan source failure suppresses successful-end collection" {
    const source = zrx.Stream(u32).fromProducer(1, failingSource);
    try std.testing.expectError(error.SourceFailed, run(.{ allocator, io }, .{
        pipe(&source, .{ scan(@as(u64, 0), add), collectThen(unexpected) }),
    }));
}

const Iterator = struct {
    calls: u32 = 0,
    pub fn next(self: *@This()) error{EndFailed}!?u32 {
        self.calls += 1;
        return if (self.calls <= 3) self.calls else error.EndFailed;
    }
};

test "scan prefixes do not probe ahead and borrowed iterators resume on rerun" {
    var iterator: Iterator = .{};
    var saved: Saved = .{};
    const accumulated = pipe(fromIterator(&iterator), .{scan(@as(u64, 10), add)});
    try run(.{ allocator, io, &saved }, .{
        pipe(&accumulated, .{ take(2), collectThen(Saved.save) }),
    });
    try saved.expect(&.{ 11, 13 });
    try std.testing.expectEqual(@as(u32, 2), iterator.calls);
    try run(.{ allocator, io, &saved }, .{
        pipe(&accumulated, .{ take(1), collectThen(Saved.save) }),
    });
    try saved.expect(&.{13});
    try std.testing.expectError(error.EndFailed, run(.{ allocator, io }, .{
        pipe(&accumulated, .{collectThen(unexpected)}),
    }));
    try std.testing.expectEqual(@as(u32, 4), iterator.calls);
}

test "zero scan prefix acquires selected dependencies but does not read" {
    var iterator: Iterator = .{};
    var lifetime: Lifetime = .{};
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved, &lifetime, zrx.resource(@as(u32, 2), acquire, release) }, .{
        pipe(fromIterator(&iterator), .{ scan(@as(u64, 0), scaled), take(0), collectThen(Saved.save) }),
    });
    try std.testing.expectEqual(@as(u32, 0), iterator.calls);
    try std.testing.expect(lifetime.acquired and lifetime.released);
    try saved.expect(&.{});
}

const Snapshot = struct { items: [3]u32 = .{ 0, 0, 0 }, len: usize = 0 };
fn append(state: Snapshot, item: u32) Snapshot {
    var result = state;
    result.items[result.len] = item;
    result.len += 1;
    return result;
}
fn checkSnapshots(items: []const Snapshot) !void {
    try std.testing.expectEqual(@as(usize, 3), items.len);
    for (items, 1..) |snapshot, n| {
        try std.testing.expectEqual(n, snapshot.len);
        try std.testing.expectEqualSlices(u32, (&[_]u32{ 1, 2, 3 })[0..n], snapshot.items[0..n]);
        for (snapshot.items[n..]) |unused| try std.testing.expectEqual(@as(u32, 0), unused);
    }
}

test "collected scan snapshots own their inline accumulator bytes" {
    try run(.{ allocator, io }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{ scan(Snapshot{}, append), collectThen(checkSnapshots) }),
    });
}
