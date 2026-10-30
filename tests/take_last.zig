const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const collectThenWith = zrx.collectThenWith;
const fromIterator = zrx.fromIterator;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Saved = struct {
    values: [128]u32 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn append(self: *@This(), value: u32) !void {
        if (self.len == self.values.len) return error.NoSpaceLeft;
        self.values[self.len] = value;
        self.len += 1;
    }
    fn copy(self: *@This(), values: []const u32) !void {
        if (values.len > self.values.len) return error.NoSpaceLeft;
        @memcpy(self.values[0..values.len], values);
        self.len = values.len;
        self.calls += 1;
    }
    fn slice(self: *@This()) []const u32 {
        return self.values[0..self.len];
    }
};

fn logs(output: *Emitter(u32)) !void {
    for (1..1001) |value| try output.push(@intCast(value));
}

test "1000 logs retain only the final 100 in original order with one shared producer" {
    const Helpers = struct {
        fn source(calls: *std.atomic.Value(usize), output: *Emitter(u32)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try logs(output);
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &calls);
    const tail = pipe(&source, .{takeLast(100)});
    var whole: Saved = .{};
    var per_item: Saved = .{};
    const collection = pipe(&tail, .{collectThenWith(&whole, Saved.copy)});
    const iteration = pipe(&tail, .{forEachWith(&per_item, Saved.append)});
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), whole.calls);
    try run(allocator, io, .{ collection, iteration });
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), whole.calls);
    try std.testing.expectEqual(@as(usize, 100), whole.len);
    for (whole.slice(), 901..) |value, expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), value);
    try std.testing.expectEqualSlices(u32, whole.slice(), per_item.slice());
    // No retained history belongs to the description between executions.
    per_item.len = 0;
    try run(allocator, io, .{ collection, iteration });
    try std.testing.expectEqual(@as(usize, 2), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), whole.calls);
    try std.testing.expectEqualSlices(u32, whole.slice(), per_item.slice());
}

test "finite suffix edge cases include zero one exact and oversized capacities" {
    const values = [_]u32{ 1, 2, 3, 4, 5 };
    for ([_]usize{ 0, 1, 3, 5, 8 }) |limit| {
        var saved: Saved = .{};
        const flow = pipe(&values, .{ takeLast(limit), collectThenWith(&saved, Saved.copy) });
        try run(allocator, io, .{flow});
        try std.testing.expectEqualSlices(u32, values[values.len - @min(values.len, limit) ..], saved.slice());
        try std.testing.expectEqual(@as(usize, 1), saved.calls);
    }
    const empty = [_]u32{};
    for ([_]usize{ 0, 3 }) |limit| {
        var saved: Saved = .{};
        try run(allocator, io, .{pipe(&empty, .{ takeLast(limit), collectThenWith(&saved, Saved.copy) })});
        try std.testing.expectEqual(@as(usize, 0), saved.len);
        try std.testing.expectEqual(@as(usize, 1), saved.calls);
    }
}

test "filtering mapping and type transitions compose around retained output" {
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
        fn widen(value: u32) u64 {
            return @as(u64, value) * 2;
        }
        fn verify(calls: *usize, values: []const u64) !void {
            try std.testing.expectEqualSlices(u64, &.{ 12, 16 }, values);
            calls.* += 1;
        }
    };
    const values = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var calls: usize = 0;
    try run(allocator, io, .{pipe(&values, .{
        filter(Helpers.even),
        takeLast(2),
        each(Helpers.widen),
        collectThenWith(&calls, Helpers.verify),
    })});
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "retained error-union optional elements stay data" {
    const Data = error{Bad}!?u32;
    const Helpers = struct {
        fn verify(calls: *usize, values: []const Data) !void {
            try std.testing.expectEqual(@as(usize, 3), values.len);
            try std.testing.expectError(error.Bad, values[0]);
            try std.testing.expectEqual(@as(?u32, null), try values[1]);
            try std.testing.expectEqual(@as(?u32, 7), try values[2]);
            calls.* += 1;
        }
    };
    const values = [_]Data{ 1, 2, error.Bad, null, 7 };
    var calls: usize = 0;
    try run(allocator, io, .{pipe(&values, .{ takeLast(3), collectThenWith(&calls, Helpers.verify) })});
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "no retained items or collection callback are delivered before successful end" {
    const State = struct {
        at_end: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        item_calls: std.atomic.Value(usize) = .init(0),
        collection_calls: std.atomic.Value(usize) = .init(0),
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
            state.at_end.set(io);
            try state.finish.wait(io);
        }
        fn item(state: *State, _: u32) void {
            _ = state.item_calls.fetchAdd(1, .monotonic);
        }
        fn collection(state: *State, values: []const u32) !void {
            try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, values);
            _ = state.collection_calls.fetchAdd(1, .monotonic);
        }
        fn execute(state: *State) !void {
            const source_description = Stream(u32).fromProducerWith(1, source, state);
            const tail = pipe(&source_description, .{takeLast(2)});
            try run(allocator, io, .{
                pipe(&tail, .{forEachWith(state, item)}),
                pipe(&tail, .{collectThenWith(state, collection)}),
            });
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.at_end.wait(io);
    try std.testing.expectEqual(@as(usize, 0), state.item_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), state.collection_calls.load(.monotonic));
    state.finish.set(io);
    try task.await(io);
    try std.testing.expectEqual(@as(usize, 2), state.item_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), state.collection_calls.load(.monotonic));
}

test "source and iterator errors discard retained data including at zero capacity" {
    const Helpers = struct {
        fn source(output: *Emitter(u32)) !void {
            try output.push(1);
            try output.push(2);
            return error.Broken;
        }
    };
    const Cursor = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.calls += 1;
            return if (self.calls < 3) @intCast(self.calls) else error.Broken;
        }
    };
    const source = Stream(u32).fromProducer(1, Helpers.source);
    for ([_]usize{ 0, 1, 3 }) |limit| {
        var per_item: Saved = .{};
        var whole: Saved = .{};
        const tail = pipe(&source, .{takeLast(limit)});
        try std.testing.expectError(error.Broken, run(allocator, io, .{
            pipe(&tail, .{forEachWith(&per_item, Saved.append)}),
            pipe(&tail, .{collectThenWith(&whole, Saved.copy)}),
        }));
        try std.testing.expectEqual(@as(usize, 0), per_item.len);
        try std.testing.expectEqual(@as(usize, 0), whole.calls);
        var cursor: Cursor = .{};
        try std.testing.expectError(error.Broken, run(allocator, io, .{
            pipe(fromIterator(&cursor), .{ takeLast(limit), collectThenWith(&whole, Saved.copy) }),
        }));
        try std.testing.expectEqual(@as(usize, 0), whole.calls);
    }
}

test "maxItems before retention checks total input while after it checks the suffix" {
    const values = [_]u32{ 1, 2, 3, 4 };
    var saved: Saved = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&values, .{ maxItems(2), takeLast(2), collectThenWith(&saved, Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try run(allocator, io, .{
        pipe(&values, .{ takeLast(2), maxItems(2), collectThenWith(&saved, Saved.copy) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, saved.slice());
    saved = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&values, .{ takeLast(2), maxItems(1), collectThenWith(&saved, Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "parent cancellation releases a populated ring without delivering its suffix" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
        saved: Saved = .{},
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            defer state.finished.store(true, .release);
            for (0..32) |_| try output.push(1);
            state.entered.set(io);
            try state.gate.wait(io);
        }
        fn execute(state: *State) !void {
            const source_description = Stream(u32).fromProducerWith(1, source, state);
            try run(allocator, io, .{
                pipe(&source_description, .{ takeLast(5), collectThenWith(&state.saved, Saved.copy) }),
            });
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(state.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.saved.calls);
}

test "downstream failure cancels retained publication and frees the ring" {
    const Helpers = struct {
        fn reject(_: u32) error{Stop}!void {
            return error.Stop;
        }
    };
    const source = Stream(u32).fromProducer(1, logs);
    try std.testing.expectError(error.Stop, run(allocator, io, .{
        pipe(&source, .{ takeLast(100), forEach(Helpers.reject) }),
    }));
}

test "consumer startup failure frees a cold ring without activating the source" {
    const Helpers = struct {
        fn source(calls: *std.atomic.Value(usize), output: *Emitter(u32)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(1);
            try output.push(2);
        }
        fn ignore(_: u32) void {}
    };
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &calls);
    const tail = pipe(&source, .{takeLast(2)});
    const first = pipe(&tail, .{forEach(Helpers.ignore)});
    const second = pipe(&tail, .{forEach(Helpers.ignore)});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{ first, second }));
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try run(allocator, io, .{first});
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const values = [_]u32{ 1, 2, 3, 4, 5, 6, 7 };
    var saved: Saved = .{};
    run(gpa, io, .{pipe(&values, .{ takeLast(4), collectThenWith(&saved, Saved.copy) })}) catch |err| {
        if (err == error.OutOfMemory) try std.testing.expectEqual(@as(usize, 0), saved.calls);
        return err;
    };
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 6, 7 }, saved.slice());
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "allocation failures clean up preallocated rings and collection storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
