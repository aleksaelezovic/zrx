const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const merge = zrx.merge;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const batchThen = zrx.batchThen;
const batchThenWith = zrx.batchThenWith;
const collectThenWith = zrx.collectThenWith;
const fromIterator = zrx.fromIterator;
const readFrom = zrx.readFrom;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Stats = struct {
    values: [1024]u32 = undefined,
    sizes: [32]usize = undefined,
    len: usize = 0,
    batches: usize = 0,
    buffer_address: ?usize = null,

    fn copy(self: *@This(), values: []const u32) !void {
        if (values.len == 0) return error.UnexpectedEmptyBatch;
        if (self.batches == self.sizes.len or values.len > self.values.len - self.len)
            return error.NoSpaceLeft;
        // Save only an address token, never a borrowed slice for later access.
        const address = @intFromPtr(values.ptr);
        if (self.buffer_address) |expected| try std.testing.expectEqual(expected, address);
        self.buffer_address = address;
        @memcpy(self.values[self.len..][0..values.len], values);
        self.sizes[self.batches] = values.len;
        self.len += values.len;
        self.batches += 1;
    }
    fn slice(self: *@This()) []const u32 {
        return self.values[0..self.len];
    }
    fn batchSizes(self: *@This()) []const usize {
        return self.sizes[0..self.batches];
    }
};

fn logs(calls: *std.atomic.Value(usize), output: *Emitter(u32)) !void {
    _ = calls.fetchAdd(1, .monotonic);
    for (1..1001) |value| try output.push(@intCast(value));
}

test "1000 logs produce ten batches of 100 using one reusable buffer per run" {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, logs, &calls);
    var stats: Stats = .{};
    const flow = pipe(&source, .{batchThenWith(100, &stats, Stats.copy)});
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), stats.batches);
    for (0..2) |execution| {
        // Application state is explicitly reset; the declaration owns no history.
        stats = .{};
        try run(allocator, io, .{flow});
        try std.testing.expectEqual(@as(usize, 10), stats.batches);
        try std.testing.expectEqual(@as(usize, 1000), stats.len);
        for (stats.batchSizes()) |size| try std.testing.expectEqual(@as(usize, 100), size);
        for (stats.slice(), 1..) |value, expected|
            try std.testing.expectEqual(@as(u32, @intCast(expected)), value);
        try std.testing.expectEqual(execution + 1, calls.load(.monotonic));
    }
}

const fixture = [_]u32{ 1, 2, 3, 4, 5 };

test "finite batches cover one-item exact partial and oversized sizes without empty callbacks" {
    for ([_]usize{ 1, 2, 5, 8 }) |size| {
        var stats: Stats = .{};
        try run(allocator, io, .{pipe(&fixture, .{batchThenWith(size, &stats, Stats.copy)})});
        try std.testing.expectEqualSlices(u32, &fixture, stats.slice());
        try std.testing.expectEqual((fixture.len + size - 1) / size, stats.batches);
        for (stats.batchSizes(), 0..) |actual, index|
            try std.testing.expectEqual(@min(size, fixture.len - index * size), actual);
    }
    const empty = [_]u32{};
    var stats: Stats = .{};
    try run(allocator, io, .{pipe(&empty, .{batchThenWith(3, &stats, Stats.copy)})});
    try std.testing.expectEqual(@as(usize, 0), stats.batches);
    const Helpers = struct {
        fn never(_: u32) bool {
            return false;
        }
    };
    try run(allocator, io, .{pipe(&fixture, .{ filter(Helpers.never), batchThenWith(3, &stats, Stats.copy) })});
    try std.testing.expectEqual(@as(usize, 0), stats.batches);
}

test "unary void callbacks and fully comptime declarations become mutable runtime flows" {
    const Helpers = struct {
        var calls: usize = 0;
        var items: usize = 0;
        fn consume(values: []const u32) void {
            calls += 1;
            items += values.len;
        }
    };
    Helpers.calls = 0;
    Helpers.items = 0;
    const flow = comptime pipe(&fixture, .{batchThen(2, Helpers.consume)});
    try std.testing.expectEqual(@as(usize, 0), Helpers.calls);
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 3), Helpers.calls);
    try std.testing.expectEqual(@as(usize, 5), Helpers.items);
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 6), Helpers.calls);
    try std.testing.expectEqual(@as(usize, 10), Helpers.items);
}

test "invalid size rejects all selected activation and frees earlier prepared buffers" {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, logs, &calls);
    const empty = [_]u32{};
    var stats: Stats = .{};
    const valid = pipe(&source, .{batchThenWith(100, &stats, Stats.copy)});
    const invalid = pipe(&empty, .{batchThenWith(0, &stats, Stats.copy)});
    try std.testing.expectError(error.InvalidBatchSize, run(allocator, io, .{ valid, invalid }));
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), stats.batches);
    try run(allocator, io, .{valid});
    try std.testing.expectEqual(@as(usize, 10), stats.batches);
}

test "unselected invalid batch flows do not validate activate or retain readers" {
    var ignored: Stats = .{};
    var selected: Stats = .{};
    _ = pipe(&fixture, .{batchThenWith(0, &ignored, Stats.copy)});
    const flow = pipe(&fixture, .{batchThenWith(2, &selected, Stats.copy)});
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 0), ignored.batches);
    try std.testing.expectEqualSlices(u32, &fixture, selected.slice());
}

test "full batches arrive while input is open and partial batches wait for successful end" {
    const State = struct {
        first_batch: std.Io.Event = .unset,
        waiting_to_close: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        calls: std.atomic.Value(usize) = .init(0),
        stats: Stats = .{},
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
            try state.first_batch.wait(io);
            try output.push(4);
            try output.push(5);
            state.waiting_to_close.set(io);
            try state.finish.wait(io);
        }
        fn consume(state: *State, values: []const u32) !void {
            try state.stats.copy(values);
            const previous = state.calls.fetchAdd(1, .acq_rel);
            if (previous == 0) state.first_batch.set(io);
        }
        fn execute(state: *State) !void {
            const source = Stream(u32).fromProducerWith(1, produce, state);
            try run(allocator, io, .{pipe(&source, .{batchThenWith(3, state, consume)})});
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.waiting_to_close.wait(io);
    try std.testing.expectEqual(@as(usize, 1), state.calls.load(.acquire));
    state.finish.set(io);
    try task.await(io);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, state.stats.batchSizes());
    try std.testing.expectEqualSlices(u32, &fixture, state.stats.slice());
}

test "source errors preserve full-batch effects but discard the pending partial batch" {
    const Helpers = struct {
        fn broken(output: *Emitter(u32)) !void {
            for (fixture) |value| try output.push(value);
            return error.Broken;
        }
    };
    const source = Stream(u32).fromProducer(1, Helpers.broken);
    for ([_]usize{ 3, 5, 8 }) |size| {
        var stats: Stats = .{};
        try std.testing.expectError(error.Broken, run(allocator, io, .{
            pipe(&source, .{batchThenWith(size, &stats, Stats.copy)}),
        }));
        const accepted = fixture.len / size * size;
        try std.testing.expectEqualSlices(u32, fixture[0..accepted], stats.slice());
        try std.testing.expectEqual(fixture.len / size, stats.batches);
    }
    const Cursor = struct {
        next_value: u32 = 1,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            if (self.next_value == 6) return error.Broken;
            const value = self.next_value;
            self.next_value += 1;
            return value;
        }
    };
    var cursor: Cursor = .{};
    var stats: Stats = .{};
    try std.testing.expectError(error.Broken, run(allocator, io, .{
        pipe(fromIterator(&cursor), .{batchThenWith(3, &stats, Stats.copy)}),
    }));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, stats.slice());
    try std.testing.expectEqual(@as(usize, 1), stats.batches);
}

test "batching preserves optional and error-union items as data" {
    const Data = error{Bad}!?u32;
    const Check = struct {
        calls: usize = 0,
        fn consume(self: *@This(), values: []const Data) !void {
            switch (self.calls) {
                0 => {
                    try std.testing.expectEqual(@as(usize, 2), values.len);
                    try std.testing.expectEqual(@as(?u32, 1), try values[0]);
                    try std.testing.expectError(error.Bad, values[1]);
                },
                1 => {
                    try std.testing.expectEqual(@as(usize, 2), values.len);
                    try std.testing.expectEqual(@as(?u32, null), try values[0]);
                    try std.testing.expectEqual(@as(?u32, 7), try values[1]);
                },
                2 => {
                    try std.testing.expectEqual(@as(usize, 1), values.len);
                    try std.testing.expectEqual(@as(?u32, 8), try values[0]);
                },
                else => return error.UnexpectedBatch,
            }
            self.calls += 1;
        }
    };
    const values = [_]Data{ 1, error.Bad, null, 7, 8 };
    var check: Check = .{};
    try run(allocator, io, .{pipe(&values, .{batchThenWith(2, &check, Check.consume)})});
    try std.testing.expectEqual(@as(usize, 3), check.calls);
}

test "batching follows type transitions and normal capability pointer coercions" {
    const Check = struct {
        calls: *usize,
        fn even(value: u8) bool {
            return value % 2 == 0;
        }
        fn widen(value: u32) u64 {
            return @as(u64, value) * 10;
        }
        fn consume(self: *const @This(), values: []const u64) !void {
            if (self.calls.* == 0)
                try std.testing.expectEqualSlices(u64, &.{ 20, 40 }, values)
            else
                try std.testing.expectEqualSlices(u64, &.{60}, values);
            self.calls.* += 1;
        }
    };
    var calls: usize = 0;
    var check: Check = .{ .calls = &calls };
    const values = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try run(allocator, io, .{pipe(&values, .{
        filter(Check.even),
        each(Check.widen),
        batchThenWith(2, &check, Check.consume),
    })});
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "a maxItems failure discards an incomplete batch instead of treating it as normal end" {
    var stats: Stats = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&fixture, .{ maxItems(4), batchThenWith(3, &stats, Stats.copy) }),
    }));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, stats.slice());
    try std.testing.expectEqual(@as(usize, 1), stats.batches);
}

test "queue closure flushes a final partial batch" {
    var storage: [3]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);
    for ([_]u32{ 1, 2, 3 }) |value| try queue.putOne(io, value);
    queue.close(io);
    var stats: Stats = .{};
    try run(allocator, io, .{pipe(readFrom(io, &queue), .{batchThenWith(2, &stats, Stats.copy)})});
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, stats.batchSizes());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, stats.slice());
}

test "batch callbacks over a shared merged retained graph match whole collection" {
    const Whole = struct {
        values: [16]u32 = undefined,
        len: usize = 0,
        fn copy(self: *@This(), values: []const u32) void {
            @memcpy(self.values[0..values.len], values);
            self.len = values.len;
        }
    };
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
        fn double(value: u32) u32 {
            return value * 2;
        }
    };
    const values = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const selected = pipe(&values, .{ filter(Helpers.even), each(Helpers.double), takeLast(3) });
    const combined = merge(.{ &selected, &selected });
    var stats: Stats = .{};
    var whole: Whole = .{};
    try run(allocator, io, .{
        pipe(&combined, .{ maxItems(6), batchThenWith(4, &stats, Stats.copy) }),
        pipe(&combined, .{collectThenWith(&whole, Whole.copy)}),
    });
    try std.testing.expectEqualSlices(usize, &.{ 4, 2 }, stats.batchSizes());
    try std.testing.expectEqualSlices(u32, whole.values[0..whole.len], stats.slice());
    var counts: [3]usize = @splat(0);
    for (stats.slice()) |value| {
        switch (value) {
            8 => counts[0] += 1,
            12 => counts[1] += 1,
            16 => counts[2] += 1,
            else => return error.UnexpectedItem,
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, &counts);
}

test "full and final-partial callback errors stop further batching without rollback" {
    const Reject = struct {
        stats: Stats = .{},
        fail_at: usize,
        fn consume(self: *@This(), values: []const u32) !void {
            try self.stats.copy(values);
            if (self.stats.batches == self.fail_at) return error.Stop;
        }
    };
    for ([_]usize{ 1, 3 }) |fail_at| {
        var reject: Reject = .{ .fail_at = fail_at };
        try std.testing.expectError(error.Stop, run(allocator, io, .{
            pipe(&fixture, .{batchThenWith(2, &reject, Reject.consume)}),
        }));
        try std.testing.expectEqual(fail_at, reject.stats.batches);
        try std.testing.expectEqualSlices(u32, fixture[0..@min(fail_at * 2, fixture.len)], reject.stats.slice());
    }
}

test "callback failure cancels a blocked peer callback before buffers are released" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        callback_finished: std.atomic.Value(bool) = .init(false),
        source_finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.source_finished.store(true, .release);
            while (true) try output.push(1);
        }
        fn reject(state: *State, _: []const u32) !void {
            try state.entered.wait(io);
            return error.Stop;
        }
        fn wait(state: *State, values: []const u32) !void {
            defer {
                for (values) |value| std.debug.assert(value == 1);
                state.callback_finished.store(true, .release);
            }
            state.entered.set(io);
            try state.gate.wait(io);
        }
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.produce, &state);
    try std.testing.expectError(error.Stop, run(allocator, io, .{
        pipe(&fixture, .{batchThenWith(2, &state, Helpers.reject)}),
        pipe(&source, .{batchThenWith(3, &state, Helpers.wait)}),
    }));
    try std.testing.expect(state.callback_finished.load(.acquire));
    try std.testing.expect(state.source_finished.load(.acquire));
}

test "parent cancellation discards an accumulated partial batch" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
        stats: Stats = .{},
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.finished.store(true, .release);
            for (0..8) |_| try output.push(1);
            state.entered.set(io);
            try state.gate.wait(io);
        }
        fn execute(state: *State) !void {
            const source = Stream(u32).fromProducerWith(1, produce, state);
            try run(allocator, io, .{pipe(&source, .{batchThenWith(16, &state.stats, Stats.copy)})});
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(state.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.stats.batches);
}

test "blocked batch callbacks backpressure the source and cancellation joins before freeing storage" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        accepted: std.atomic.Value(usize) = .init(0),
        callback_finished: std.atomic.Value(bool) = .init(false),
        source_finished: std.atomic.Value(bool) = .init(false),
        calls: usize = 0,
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.source_finished.store(true, .release);
            while (true) {
                try output.push(1);
                _ = state.accepted.fetchAdd(1, .monotonic);
            }
        }
        fn consume(state: *State, values: []const u32) !void {
            defer {
                for (values) |value| std.debug.assert(value == 1);
                state.callback_finished.store(true, .release);
            }
            try std.testing.expectEqual(@as(usize, 3), values.len);
            state.calls += 1;
            state.entered.set(io);
            try state.gate.wait(io);
        }
        fn execute(state: *State) !void {
            const source = Stream(u32).fromProducerWith(1, produce, state);
            try run(allocator, io, .{pipe(&source, .{batchThenWith(3, state, consume)})});
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.wait(io);
    // Three callback items plus one source queue slot, not unbounded draining.
    try std.testing.expect(state.accepted.load(.monotonic) <= 4);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(state.callback_finished.load(.acquire));
    try std.testing.expect(state.source_finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "startup failure frees cold prepared batch buffers without starting sources" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, logs, &calls);
    var a: Stats = .{};
    var b: Stats = .{};
    const first = pipe(&source, .{batchThenWith(100, &a, Stats.copy)});
    const second = pipe(&source, .{batchThenWith(100, &b, Stats.copy)});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{ first, second }));
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), a.batches);
    try std.testing.expectEqual(@as(usize, 0), b.batches);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(u32).fromProducerWith(1, logs, &calls);
    var stats: Stats = .{};
    run(gpa, io, .{pipe(&source, .{batchThenWith(100, &stats, Stats.copy)})}) catch |err| {
        if (err == error.OutOfMemory) {
            // All run-owned batch allocations precede producer activation.
            try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 0), stats.batches);
        }
        return err;
    };
    try std.testing.expectEqual(@as(usize, 10), stats.batches);
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
}

test "preparation allocation failures clean up without activation and batching never grows storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
