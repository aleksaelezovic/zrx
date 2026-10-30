const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const maxItems = zrx.maxItems;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const collectThen = zrx.collectThen;
const collectThenWith = zrx.collectThenWith;
const fromIterator = zrx.fromIterator;
const readFrom = zrx.readFrom;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Saved = struct {
    values: [64]u32 = undefined,
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

test "finite source terminals are lazy and referenced transforms share with collection" {
    const Helpers = struct {
        var evaluations: std.atomic.Value(usize) = .init(0);
        fn double(value: u8) u32 {
            _ = evaluations.fetchAdd(1, .monotonic);
            return @as(u32, value) * 2;
        }
    };
    Helpers.evaluations.store(0, .monotonic);
    var source = [_]u8{ 1, 2, 3 };
    const doubled = pipe(&source, .{each(Helpers.double)});
    var per_item: Saved = .{};
    var whole: Saved = .{};
    const first = pipe(&doubled, .{forEachWith(&per_item, Saved.append)});
    const second = pipe(&doubled, .{collectThenWith(&whole, Saved.copy)});
    try std.testing.expectEqual(@as(usize, 0), Helpers.evaluations.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), whole.calls);
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, whole.slice());
    try std.testing.expectEqualSlices(u32, whole.slice(), per_item.slice());
    try std.testing.expectEqual(@as(usize, 3), Helpers.evaluations.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), whole.calls);
    source[0] = 4;
    per_item.len = 0;
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqualSlices(u32, &.{ 8, 4, 6 }, whole.slice());
    try std.testing.expectEqual(@as(usize, 2), whole.calls);
}

test "slice stream and iterator terminals participate in one run" {
    const Helpers = struct {
        fn produce(output: *Emitter(u32)) !void {
            try output.push(9);
        }
    };
    const Cursor = struct {
        count: u32 = 0,
        pub fn next(self: *@This()) ?u32 {
            if (self.count == 2) return null;
            self.count += 1;
            return self.count;
        }
    };
    const values = [_]u32{ 3, 4 };
    const slice: []const u32 = &values;
    const source = Stream(u32).fromProducer(1, Helpers.produce);
    var cursor: Cursor = .{};
    var a: Saved = .{};
    var b: Saved = .{};
    var c: Saved = .{};
    var d: Saved = .{};
    const adapter = fromIterator(&cursor);
    const iterator_flow = pipe(&adapter, .{collectThenWith(&c, Saved.copy)});
    try std.testing.expectEqual(@as(u32, 0), cursor.count);
    try run(allocator, io, .{
        pipe(slice, .{collectThenWith(&a, Saved.copy)}),
        pipe(&source, .{collectThenWith(&b, Saved.copy)}),
        iterator_flow,
        pipe(&adapter, .{collectThenWith(&d, Saved.copy)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 3, 4 }, a.slice());
    try std.testing.expectEqualSlices(u32, &.{9}, b.slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, c.slice());
    try std.testing.expectEqualSlices(u32, c.slice(), d.slice());
    try run(allocator, io, .{iterator_flow});
    try std.testing.expectEqual(@as(usize, 0), c.len);
    try std.testing.expectEqual(@as(usize, 2), c.calls);
}

test "empty and all-filtered inputs invoke collection once with an empty slice" {
    const Helpers = struct {
        fn never(_: u32) bool {
            return false;
        }
    };
    const empty = [_]u32{};
    const values = [_]u32{ 1, 2 };
    var a: Saved = .{};
    var b: Saved = .{};
    try run(allocator, io, .{
        pipe(&empty, .{ maxItems(0), collectThenWith(&a, Saved.copy) }),
        pipe(&values, .{ filter(Helpers.never), collectThenWith(&b, Saved.copy) }),
    });
    try std.testing.expectEqual(@as(usize, 1), a.calls);
    try std.testing.expectEqual(@as(usize, 1), b.calls);
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
}

test "unary terminal forms accept void effects and preserve error optional items" {
    const Data = error{Bad}!?u32;
    const Helpers = struct {
        var each_calls: std.atomic.Value(usize) = .init(0);
        var collection_calls: std.atomic.Value(usize) = .init(0);
        fn item(_: Data) void {
            _ = each_calls.fetchAdd(1, .monotonic);
        }
        fn collection(values: []const Data) !void {
            try std.testing.expectEqual(@as(usize, 3), values.len);
            try std.testing.expectError(error.Bad, values[0]);
            try std.testing.expectEqual(@as(?u32, null), try values[1]);
            try std.testing.expectEqual(@as(?u32, 7), try values[2]);
            _ = collection_calls.fetchAdd(1, .monotonic);
        }
    };
    Helpers.each_calls.store(0, .monotonic);
    Helpers.collection_calls.store(0, .monotonic);
    const values = [_]Data{ error.Bad, null, 7 };
    try run(allocator, io, .{
        pipe(&values, .{forEach(Helpers.item)}),
        pipe(&values, .{collectThen(Helpers.collection)}),
    });
    try std.testing.expectEqual(@as(usize, 3), Helpers.each_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), Helpers.collection_calls.load(.monotonic));
}

test "standard queue input is deferred and collection observes closed-and-drained end" {
    var storage: [2]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);
    try queue.putOne(io, 4);
    try queue.putOne(io, 8);
    var saved: Saved = .{};
    const flow = pipe(readFrom(io, &queue), .{collectThenWith(&saved, Saved.copy)});
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    queue.close(io);
    try run(allocator, io, .{flow});
    try std.testing.expectEqualSlices(u32, &.{ 4, 8 }, saved.slice());
}

test "source failure and fallible iterator failure suppress collection callbacks" {
    const Helpers = struct {
        fn produce(output: *Emitter(u32)) !void {
            try output.push(1);
            return error.Broken;
        }
    };
    const Cursor = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.calls += 1;
            return if (self.calls == 1) 1 else error.Broken;
        }
    };
    const source = Stream(u32).fromProducer(1, Helpers.produce);
    var saved: Saved = .{};
    try std.testing.expectError(error.Broken, run(allocator, io, .{
        pipe(&source, .{collectThenWith(&saved, Saved.copy)}),
    }));
    var cursor: Cursor = .{};
    try std.testing.expectError(error.Broken, run(allocator, io, .{
        pipe(fromIterator(&cursor), .{collectThenWith(&saved, Saved.copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "collection waits for successful end even after exactly maxItems outputs" {
    const State = struct {
        at_limit: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        collected: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            try output.push(1);
            state.at_limit.set(io);
            try state.finish.wait(io);
        }
        fn collection(state: *State, values: []const u32) !void {
            try std.testing.expectEqualSlices(u32, &.{1}, values);
            state.collected.store(true, .release);
        }
        fn execute(state: *State) !void {
            const source = Stream(u32).fromProducerWith(1, produce, state);
            try run(allocator, io, .{
                pipe(&source, .{ maxItems(1), collectThenWith(state, collection) }),
            });
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.at_limit.wait(io);
    try std.testing.expect(!state.collected.load(.acquire));
    state.finish.set(io);
    try task.await(io);
    try std.testing.expect(state.collected.load(.acquire));
}

test "maxItems counts outputs at its position and never forwards the excess element" {
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
    };
    const values = [_]u32{ 1, 2, 3, 4 };
    var saved: Saved = .{};
    try run(allocator, io, .{
        pipe(&values, .{ filter(Helpers.even), maxItems(2), collectThenWith(&saved, Saved.copy) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, saved.slice());
    saved = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&values, .{ maxItems(2), forEachWith(&saved, Saved.append) }),
    }));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, saved.slice());
    saved = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&values, .{ maxItems(2), collectThenWith(&saved, Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&values, .{ maxItems(0), forEachWith(&saved, Saved.append) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.len);
}

test "collection callback failure frees storage and cancels blocked peers" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        peer_finished: std.atomic.Value(bool) = .init(false),
        source_finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            defer state.source_finished.store(true, .release);
            while (true) try output.push(1);
        }
        fn reject(state: *State, _: []const u32) !void {
            try state.entered.wait(io);
            return error.Stop;
        }
        fn wait(state: *State, _: u32) !void {
            defer state.peer_finished.store(true, .release);
            state.entered.set(io);
            try state.gate.wait(io);
        }
    };
    var state: State = .{};
    const values = [_]u32{ 1, 2 };
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    try std.testing.expectError(error.Stop, run(allocator, io, .{
        pipe(&values, .{collectThenWith(&state, Helpers.reject)}),
        pipe(&source, .{forEachWith(&state, Helpers.wait)}),
    }));
    try std.testing.expect(state.peer_finished.load(.acquire));
    try std.testing.expect(state.source_finished.load(.acquire));
}

test "parent cancellation discards a partial collection without invoking its callback" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
        saved: Saved = .{},
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.finished.store(true, .release);
            // Capacity one forces collection to accumulate a prefix before
            // production can reach the cancellation barrier.
            for (0..32) |_| try output.push(1);
            state.entered.set(io);
            try state.gate.wait(io);
        }
        fn execute(state: *State) !void {
            const source = Stream(u32).fromProducerWith(1, produce, state);
            try run(allocator, io, .{pipe(&source, .{collectThenWith(&state.saved, Saved.copy)})});
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

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const values: [32]u32 = @splat(7);
    var saved: Saved = .{};
    const flow = pipe(&values, .{collectThenWith(&saved, Saved.copy)});
    run(gpa, io, .{flow}) catch |err| {
        if (err == error.OutOfMemory) try std.testing.expectEqual(@as(usize, 0), saved.calls);
        return err;
    };
    try std.testing.expectEqualSlices(u32, &values, saved.slice());
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "preparation and collection-growth allocation failures release all run-owned storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
