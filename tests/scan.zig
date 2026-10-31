const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const scan = zrx.scan;
const each = zrx.each;
const filter = zrx.filter;
const map = zrx.map;
const merge = zrx.merge;
const take = zrx.take;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const fromIterator = zrx.fromIterator;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const collectThenWith = zrx.collectThenWith;
const batchThenWith = zrx.batchThenWith;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn Saved(comptime T: type) type {
    return struct {
        data: [64]T = undefined,
        len: usize = 0,
        calls: usize = 0,
        fn append(self: *@This(), value: T) !void {
            if (self.len == self.data.len) return error.NoSpaceLeft;
            self.data[self.len] = value;
            self.len += 1;
        }
        fn copy(self: *@This(), items: []const T) !void {
            if (items.len > self.data.len) return error.NoSpaceLeft;
            @memcpy(self.data[0..items.len], items);
            self.len = items.len;
            self.calls += 1;
        }
        fn slice(self: *@This()) []const T {
            return self.data[0..self.len];
        }
    };
}

// Deliberately open sources must complete through retirement, not EOF.
fn runWithin(flows: anytype) !void {
    const Definitions = @Tuple(@typeInfo(@TypeOf(flows)).@"struct".field_types);
    const State = struct {
        definitions: Definitions = undefined,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            try run(allocator, io, self.definitions);
        }
    };
    var state: State = .{};
    inline for (0..flows.len) |i| state.definitions[i] = flows[i];
    var task = try io.concurrent(State.execute, .{&state});
    defer task.cancel(io) catch {};
    try wait(&state.done);
    try task.await(io);
}

fn wait(event: *std.Io.Event) !void {
    try event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
}

fn add(total: u64, value: u32) u64 {
    return total +% value;
}
fn even(value: u32) bool {
    return value % 2 == 0;
}
fn twice(value: u32) u32 {
    return value *% 2;
}
fn increment(value: u32) u32 {
    return value +% 1;
}

test "runtime seeds are copied at declaration and reset on every run without seed emission" {
    const input = [_]u8{ 3, 5, 0 };
    var seed: u16 = 10;
    const totals = pipe(&input, .{scan(seed, add)});
    seed = 99;
    var saved: Saved(u64) = .{};
    const flow = pipe(&totals, .{collectThenWith(&saved, Saved(u64).copy)});
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    for (0..2) |_| {
        try run(allocator, io, .{flow});
        try std.testing.expectEqualSlices(u64, &.{ 13, 18, 18 }, saved.slice());
    }
    try std.testing.expectEqual(@as(u16, 99), seed);
    try std.testing.expectEqual(@as(usize, 2), saved.calls);
}

test "empty all-filtered and singleton inputs never invent an initial or final result" {
    const Helpers = struct {
        fn unreachableReducer(_: u64, _: u32) u64 {
            @panic("empty scan called reducer");
        }
    };
    const empty = [_]u32{};
    const rejected = [_]u32{ 1, 3, 5 };
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    var c: Saved(u64) = .{};
    try run(allocator, io, .{
        pipe(&empty, .{ scan(9, Helpers.unreachableReducer), collectThenWith(&a, Saved(u64).copy) }),
        pipe(&rejected, .{ filter(even), scan(9, Helpers.unreachableReducer), collectThenWith(&b, Saved(u64).copy) }),
        pipe(&[_]u32{2}, .{ scan(9, add), collectThenWith(&c, Saved(u64).copy) }),
    });
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
    try std.testing.expectEqual(@as(usize, 1), a.calls);
    try std.testing.expectEqual(@as(usize, 1), b.calls);
    try std.testing.expectEqualSlices(u64, &.{11}, c.slice());
}

test "left recurrence composes with grouped or separate transforms and result filtering" {
    const Helpers = struct {
        fn digit(total: u64, value: u32) u64 {
            return total * 10 + value;
        }
        fn large(total: u64) bool {
            return total > 95;
        }
    };
    const input = [_]u32{ 1, 2, 3 };
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    try run(allocator, io, .{
        pipe(&input, .{ each(.{ twice, increment }), scan(9, Helpers.digit), filter(Helpers.large), collectThenWith(&a, Saved(u64).copy) }),
        try tryPipe(&input, .{ each(twice), each(.{increment}), scan(9, Helpers.digit), filter(Helpers.large), collectThenWith(&b, Saved(u64).copy) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 935, 9357 }, a.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), b.slice());
}

test "inline arrays in accumulator snapshots do not alias changing worker storage" {
    const State = struct {
        items: [3]u32 = .{ 0, 0, 0 },
        used: usize = 0,
        fn append(previous: @This(), value: u32) @This() {
            var next = previous;
            next.items[next.used] = value;
            next.used += 1;
            return next;
        }
    };
    const input = [_]u32{ 2, 4, 6 };
    var saved: Saved(State) = .{};
    try run(allocator, io, .{pipe(&input, .{ scan(State{}, State.append), collectThenWith(&saved, Saved(State).copy) })});
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 0 }, &saved.data[0].items);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 0 }, &saved.data[1].items);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, &saved.data[2].items);
    try std.testing.expectEqual(@as(usize, 3), saved.len);
}

test "optional and error-valued items and boxed error state stay data under tryPipe" {
    const Data = error{Missing}!?u32;
    const State = struct { sum: u64 = 0, last_error: ?error{Missing} = null };
    const Helpers = struct {
        fn update(previous: State, value: Data) State {
            var next = previous;
            const item = value catch |err| {
                next.last_error = err;
                return next;
            };
            next.sum += item orelse 10;
            return next;
        }
        fn optional(previous: ?u64, value: u32) ?u64 {
            return (previous orelse 0) + value;
        }
    };
    const input = [_]Data{ 2, error.Missing, null, 3 };
    var saved: Saved(State) = .{};
    var optional: Saved(?u64) = .{};
    try run(allocator, io, .{
        try tryPipe(&input, .{ scan(State{}, Helpers.update), collectThenWith(&saved, Saved(State).copy) }),
        pipe(&[_]u32{ 1, 0 }, .{ scan(null, Helpers.optional), collectThenWith(&optional, Saved(?u64).copy) }),
    });
    try std.testing.expectEqualDeep(
        &[_]State{ .{ .sum = 2 }, .{ .sum = 2, .last_error = error.Missing }, .{ .sum = 12, .last_error = error.Missing }, .{ .sum = 15, .last_error = error.Missing } },
        saved.slice(),
    );
    try std.testing.expectEqualSlices(?u64, &.{ 1, 1 }, optional.slice());
}

test "immutable borrowed referents remain shallow and consuming adapters are not rewound" {
    const State = struct {
        label: []const u8,
        count: usize = 0,
        fn update(previous: @This(), item: []const u8) @This() {
            return .{ .label = previous.label, .count = previous.count + item.len };
        }
    };
    const label: []const u8 = "bytes";
    var cursor = std.mem.splitScalar(u8, "a,bb", ',');
    const totals = pipe(fromIterator(&cursor), .{scan(State{ .label = label }, State.update)});
    var saved: Saved(State) = .{};
    const flow = pipe(&totals, .{collectThenWith(&saved, Saved(State).copy)});
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 3), saved.data[1].count);
    try std.testing.expectEqual(label.ptr, saved.data[0].label.ptr);
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 0), saved.len);
}

test "stable references share one recurrence but by-value copies reduce independently" {
    const Helpers = struct {
        // Instrumentation only: application reducers must be pure.
        var reductions: std.atomic.Value(usize) = .init(0);
        fn count(total: u64, item: u32) u64 {
            _ = reductions.fetchAdd(1, .monotonic);
            return add(total, item);
        }
        fn source(calls: *usize, output: *Emitter(u32)) !void {
            calls.* += 1;
            for ([_]u32{ 1, 2, 3 }) |item| try output.push(item);
        }
    };
    Helpers.reductions.store(0, .monotonic);
    var calls: usize = 0;
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &calls);
    const totals = pipe(&source, .{scan(5, Helpers.count)});
    _ = pipe(&source, .{scan(99, Helpers.count)}); // Unselected.
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    var c: Saved(u64) = .{};
    var d: Saved(u64) = .{};
    try std.testing.expectEqual(@as(usize, 0), Helpers.reductions.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), calls);
    try run(allocator, io, .{
        pipe(&totals, .{collectThenWith(&a, Saved(u64).copy)}),
        pipe(&totals, .{forEachWith(&b, Saved(u64).append)}),
        pipe(totals, .{collectThenWith(&c, Saved(u64).copy)}),
        pipe(totals, .{collectThenWith(&d, Saved(u64).copy)}),
    });
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 9), Helpers.reductions.load(.monotonic));
    try std.testing.expectEqualSlices(u64, &.{ 6, 8, 11 }, a.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), b.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), c.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), d.slice());
}

test "a blocked observer applies lossless backpressure without blocking its sibling callback" {
    const State = struct {
        release: std.Io.Event = .unset,
        fast_progress: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        slow: Saved(u64) = .{},
        fast: Saved(u64) = .{},
    };
    const Helpers = struct {
        // Instrumentation only, not permission for effectful application reducers.
        var calls: std.atomic.Value(usize) = .init(0);
        fn count(previous: u64, item: u32) u64 {
            _ = calls.fetchAdd(1, .monotonic);
            return add(previous, item);
        }
        fn slow(state: *State, value: u64) !void {
            if (value == 1) try state.release.wait(io);
            try state.slow.append(value);
        }
        fn fast(state: *State, value: u64) !void {
            try state.fast.append(value);
            if (value == 2) state.fast_progress.set(io);
        }
        fn execute(state: *State) !void {
            defer state.done.set(io);
            const input: [8]u32 = @splat(1);
            const totals = pipe(&input, .{scan(0, count)});
            try run(allocator, io, .{
                pipe(&totals, .{forEachWith(state, slow)}),
                pipe(&totals, .{forEachWith(state, fast)}),
            });
        }
    };
    Helpers.calls.store(0, .monotonic);
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    defer state.release.set(io);
    try wait(&state.fast_progress);
    // The slow reader has consumed the first slot but not the second.
    // One more state may be computed waiting to publish, never the whole input.
    const calls = Helpers.calls.load(.monotonic);
    try std.testing.expect(calls >= 2 and calls <= 3);
    state.release.set(io);
    try wait(&state.done);
    try task.await(io);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, state.slow.slice());
    try std.testing.expectEqualSlices(u64, state.slow.slice(), state.fast.slice());
    try std.testing.expectEqual(@as(usize, 8), Helpers.calls.load(.monotonic));
}

test "scan after merge follows its chosen interleaving without separate input accumulators" {
    const a = [_]u32{ 1, 2 };
    const b = [_]u32{3};
    const events = merge(.{ &a, &b });
    var saved: Saved(u64) = .{};
    try run(allocator, io, .{pipe(&events, .{ scan(0, add), collectThenWith(&saved, Saved(u64).copy) })});
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    try std.testing.expect(saved.data[0] < saved.data[1]);
    try std.testing.expectEqual(@as(u64, 6), saved.data[2]);
}

test "zero prefix is cold and prefixes retire scan without blocking a live sibling" {
    const Helpers = struct {
        fn unreachableReducer(_: u64, _: u32) u64 {
            @panic("cold scan called reducer");
        }
        fn endless(joined: *std.atomic.Value(bool), output: *Emitter(u32)) !void {
            defer joined.store(true, .release);
            while (true) try output.push(1);
        }
    };
    var joined: std.atomic.Value(bool) = .init(false);
    const source = Stream(u32).fromProducerWith(1, Helpers.endless, &joined);
    var a: Saved(u64) = .{};
    var b: Saved(u32) = .{};
    try runWithin(.{pipe(&source, .{ scan(0, Helpers.unreachableReducer), take(0), collectThenWith(&a, Saved(u64).copy) })});
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expect(!joined.load(.acquire)); // Producer never starts.
    try runWithin(.{
        pipe(&source, .{ scan(0, add), take(2), collectThenWith(&a, Saved(u64).copy) }),
        pipe(&source, .{ take(20), collectThenWith(&b, Saved(u32).copy) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, a.slice());
    try std.testing.expectEqual(@as(usize, 20), b.len);
    try std.testing.expect(joined.load(.acquire));
}

test "hold initializes before updates and final derived totals remain sampleable" {
    const State = struct {
        initial_sampled: std.Io.Event = .unset,
        final_observed: std.Io.Event = .unset,
        observations: Saved(u64) = .{},
        samples: Saved(u64) = .{},
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            try state.initial_sampled.wait(output.io);
            try output.push(2);
            try output.push(3);
            // Input stays open; take before hold supplies successful update end.
            var gate: std.Io.Event = .unset;
            try gate.wait(output.io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try output.push(1);
            try state.final_observed.wait(output.io);
            try output.push(2);
        }
        fn double(value: u64) u64 {
            return value * 2;
        }
        fn observe(state: *State, value: u64) !void {
            try state.observations.append(value);
            if (value == 10) state.final_observed.set(io);
        }
        fn sample(state: *State, pair: @Tuple(&.{ u8, u64 })) !void {
            try state.samples.append(pair[1]);
            if (pair[0] == 1) state.initial_sampled.set(io);
        }
    };
    var state: State = .{};
    const chunks = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&chunks, .{ take(2), scan(0, add), hold(0) });
    const doubled = pipe(&current, .{map(Helpers.double)});
    try runWithin(.{
        pipe(values(&doubled), .{forEachWith(&state, Helpers.observe)}),
        pipe(&requests, .{ withLatestFrom(&doubled), forEachWith(&state, Helpers.sample) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 0, 4, 10 }, state.observations.slice());
    try std.testing.expectEqualSlices(u64, &.{ 0, 10 }, state.samples.slice());
}

test "observation prefix retirement keeps scan feeding a run-scoped state dependency" {
    const State = struct {
        observed: std.Io.Event = .unset,
        admitted: std.Io.Event = .unset,
        saved: Saved(u64) = .{},
        sample: u64 = 0,
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            try state.observed.wait(output.io);
            for (1..21) |item| try output.push(@intCast(item));
            state.admitted.set(output.io);
        }
        fn observed(state: *State, items: []const u64) !void {
            try state.saved.copy(items);
            state.observed.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.admitted.wait(output.io);
            try output.push(1);
        }
        fn sample(state: *State, pair: @Tuple(&.{ u8, u64 })) void {
            state.sample = pair[1];
        }
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&source, .{ scan(0, add), hold(0) });
    try runWithin(.{
        pipe(values(&current), .{ take(1), collectThenWith(&state, Helpers.observed) }),
        pipe(&requests, .{ withLatestFrom(&current), forEachWith(&state, Helpers.sample) }),
    });
    try std.testing.expectEqualSlices(u64, &.{0}, state.saved.slice());
    try std.testing.expect(state.sample > 0 and state.sample <= 210);
}

test "scan source failure still terminates an idle sampler after observation retirement" {
    const State = struct {
        observed: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            try state.observed.wait(output.io);
            return error.Broken;
        }
        fn observed(state: *State, _: []const u64) void {
            state.observed.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.gate.wait(output.io);
        }
        fn ignore(_: @Tuple(&.{ u8, u64 })) void {}
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&source, .{ scan(0, add), hold(0) });
    try std.testing.expectError(error.Broken, runWithin(.{
        pipe(values(&current), .{ take(1), collectThenWith(&state, Helpers.observed) }),
        pipe(&requests, .{ withLatestFrom(&current), forEach(Helpers.ignore) }),
    }));
}

test "source failure discards partial collection suffix and batch without inventing a result" {
    const Helpers = struct {
        fn broken(output: *Emitter(u32)) !void {
            try output.push(1);
            return error.Broken;
        }
    };
    const source = Stream(u32).fromProducer(1, Helpers.broken);
    const totals = pipe(&source, .{scan(0, add)});
    var collected: Saved(u64) = .{};
    var suffix: Saved(u64) = .{};
    var batch: Saved(u64) = .{};
    try std.testing.expectError(error.Broken, runWithin(.{
        pipe(&totals, .{collectThenWith(&collected, Saved(u64).copy)}),
        pipe(&totals, .{ takeLast(2), collectThenWith(&suffix, Saved(u64).copy) }),
        pipe(&totals, .{batchThenWith(16, &batch, Saved(u64).copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), collected.calls);
    try std.testing.expectEqual(@as(usize, 0), suffix.calls);
    try std.testing.expectEqual(@as(usize, 0), batch.calls);
}

test "fallible cursor failure propagates but a successful input prefix observes no later error" {
    const Cursor = struct {
        probes: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.probes += 1;
            return if (self.probes <= 2) @intCast(self.probes) else error.Broken;
        }
    };
    var cursor: Cursor = .{};
    var saved: Saved(u64) = .{};
    try std.testing.expectError(error.Broken, runWithin(.{
        pipe(fromIterator(&cursor), .{ scan(0, add), collectThenWith(&saved, Saved(u64).copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    cursor = .{};
    try runWithin(.{
        pipe(fromIterator(&cursor), .{ take(2), scan(0, add), collectThenWith(&saved, Saved(u64).copy) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, saved.slice());
}

test "successful prefix flushes batches and suffix while count guard remains an error" {
    const input = [_]u32{ 1, 2, 3, 4 };
    var batch: Saved(u64) = .{};
    var suffix: Saved(u64) = .{};
    try run(allocator, io, .{
        pipe(&input, .{ scan(0, add), take(3), batchThenWith(8, &batch, Saved(u64).copy) }),
        pipe(&input, .{ scan(0, add), take(3), takeLast(2), collectThenWith(&suffix, Saved(u64).copy) }),
    });
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 6 }, batch.slice());
    try std.testing.expectEqualSlices(u64, &.{ 3, 6 }, suffix.slice());
    var saved: Saved(u64) = .{};
    try std.testing.expectError(error.TooManyItems, run(allocator, io, .{
        pipe(&input, .{ scan(0, add), maxItems(2), collectThenWith(&saved, Saved(u64).copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "parent cancellation joins a blocked producer before releasing accumulator transport" {
    const State = struct {
        entered: std.Io.Event = .unset,
        joined: std.atomic.Value(bool) = .init(false),
        saved: Saved(u64) = .{},
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) !void {
            defer state.joined.store(true, .release);
            try output.push(1);
            state.entered.set(output.io);
            var gate: std.Io.Event = .unset;
            try gate.wait(output.io);
        }
        fn execute(state: *State) !void {
            const input = Stream(u32).fromProducerWith(1, source, state);
            try run(allocator, io, .{
                pipe(&input, .{ scan(0, add), collectThenWith(&state.saved, Saved(u64).copy) }),
            });
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try wait(&state.entered);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(state.joined.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.saved.calls);
}

test "terminal failure cancels an endless source and preserves the effect error" {
    const Helpers = struct {
        fn source(joined: *std.atomic.Value(bool), output: *Emitter(u32)) !void {
            defer joined.store(true, .release);
            while (true) try output.push(1);
        }
        fn reject(_: u64) error{Stop}!void {
            return error.Stop;
        }
    };
    var joined: std.atomic.Value(bool) = .init(false);
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &joined);
    try std.testing.expectError(error.Stop, runWithin(.{pipe(&source, .{ scan(0, add), forEach(Helpers.reject) })}));
    try std.testing.expect(joined.load(.acquire));
}

test "consumer state-worker and forwarding startup failures leave cold reducers untouched" {
    const Helpers = struct {
        fn source(calls: *usize, output: *Emitter(u32)) !void {
            calls.* += 1;
            try output.push(1);
        }
        fn unreachableReducer(_: u64, _: u32) u64 {
            @panic("startup failure called reducer");
        }
        fn ignore(_: u64) void {}
    };
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var calls: usize = 0;
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &calls);
    const totals = pipe(&source, .{scan(0, Helpers.unreachableReducer)});
    const flow = pipe(&totals, .{forEach(Helpers.ignore)});
    // Two consumers cannot start; one consumer cannot start the forwarding
    // worker; a consumer plus a signal-family worker also cannot start.
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{ flow, flow }));
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{flow}));
    const current = pipe(&totals, .{hold(0)});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{
        pipe(values(&current), .{forEach(Helpers.ignore)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), calls);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const input = [_]u32{ 1, 2, 3 };
    const totals = pipe(&input, .{scan(0, add)});
    const current = pipe(&totals, .{hold(0)});
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    try run(gpa, io, .{
        pipe(&totals, .{collectThenWith(&a, Saved(u64).copy)}),
        pipe(values(&current), .{batchThenWith(8, &b, Saved(u64).copy)}),
    });
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 6 }, a.slice());
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 3, 6 }, b.slice());
}

test "all allocation failures clean partial preparation and activated graph storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
