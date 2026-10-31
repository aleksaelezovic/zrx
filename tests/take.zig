const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const take = zrx.take;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const merge = zrx.merge;
const fold = zrx.fold;
const fromIterator = zrx.fromIterator;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const collectThenWith = zrx.collectThenWith;
const batchThenWith = zrx.batchThenWith;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Saved = struct {
    items: [128]u32 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn copy(self: *@This(), input: []const u32) !void {
        if (input.len > self.items.len) return error.NoSpaceLeft;
        @memcpy(self.items[0..input.len], input);
        self.len = input.len;
        self.calls += 1;
    }
    fn append(self: *@This(), value: u32) void {
        self.items[self.len] = value;
        self.len += 1;
    }
    fn slice(self: *@This()) []const u32 {
        return self.items[0..self.len];
    }
};

// Give early-completion/retirement regressions a deadline rather than waiting
// indefinitely for EOF from deliberately open sources.
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
    try state.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try task.await(io);
}

test "finite prefixes handle zero short exact and oversized limits without allocation" {
    const input = [_]u32{ 1, 2, 3, 4 };
    for ([_]usize{ 0, 1, 3, 4, 8 }) |limit| {
        const prefix = pipe(&input, .{take(limit)});
        var cursor = prefix.iterator();
        for (input[0..@min(limit, input.len)]) |expected|
            try std.testing.expectEqual(@as(?u32, expected), cursor.next());
        try std.testing.expectEqual(null, cursor.next());
        try std.testing.expectEqual(null, cursor.next());
    }
    const empty: []const u32 = &.{};
    var cursor = pipe(empty, .{take(3)}).iterator();
    try std.testing.expectEqual(null, cursor.next());
}

test "a consuming iterator resumes after exactly n probes and zero probes none" {
    const Cursor = struct {
        probes: usize = 0,
        next_value: u32 = 1,
        pub fn next(self: *@This()) ?u32 {
            self.probes += 1;
            defer self.next_value += 1;
            return self.next_value;
        }
    };
    var input: Cursor = .{};
    var empty = pipe(fromIterator(&input), .{take(0)}).iterator();
    try std.testing.expectEqual(null, empty.next());
    try std.testing.expectEqual(@as(usize, 0), input.probes);
    var first = pipe(fromIterator(&input), .{take(2)}).iterator();
    try std.testing.expectEqual(@as(?u32, 1), first.next());
    try std.testing.expectEqual(@as(?u32, 2), first.next());
    try std.testing.expectEqual(null, first.next());
    try std.testing.expectEqual(null, first.next());
    try std.testing.expectEqual(@as(usize, 2), input.probes);
    try std.testing.expectEqual(@as(?u32, 3), input.next());
}

test "fallible cursors propagate only errors actually observed within the prefix" {
    const Cursor = struct {
        probes: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.probes += 1;
            if (self.probes > 2) return error.Broken;
            return @intCast(self.probes);
        }
    };
    var input: Cursor = .{};
    var first = pipe(fromIterator(&input), .{take(2)}).iterator();
    try std.testing.expectEqual(@as(?u32, 1), try first.next());
    try std.testing.expectEqual(@as(?u32, 2), try first.next());
    try std.testing.expectEqual(null, try first.next());
    try std.testing.expectEqual(@as(usize, 2), input.probes);
    var failing = pipe(fromIterator(&input), .{take(1)}).iterator();
    try std.testing.expectError(error.Broken, failing.next());
}

test "take is positional and composes with finite eager folds and type transitions" {
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
        fn widen(value: u32) u64 {
            return @as(u64, value) * 2;
        }
        fn sum(total: u64, value: u64) u64 {
            return total + value;
        }
    };
    const input = [_]u32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(@as(u64, 12), pipe(&input, .{
        filter(Helpers.even), take(2), each(Helpers.widen), fold(0, Helpers.sum),
    }));
    try std.testing.expectEqual(@as(u64, 4), pipe(&input, .{
        take(2), filter(Helpers.even), each(Helpers.widen), fold(0, Helpers.sum),
    }));
}

test "optional and error-union items remain data" {
    const Data = error{Bad}!?u32;
    const input = [_]Data{ error.Bad, null, 3, 4 };
    var cursor = pipe(&input, .{take(3)}).iterator();
    try std.testing.expectError(error.Bad, cursor.next().?);
    try std.testing.expectEqual(@as(?u32, null), try cursor.next().?);
    try std.testing.expectEqual(@as(?u32, 3), try cursor.next().?);
    try std.testing.expectEqual(null, cursor.next());
}

test "a live prefix completes without source EOF and joins the canceled producer" {
    const State = struct {
        stopped: bool = false,
        gate: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.stopped = true;
            try output.push(1);
            try output.push(2);
            try state.gate.wait(output.io);
        }
    };
    var state: State = .{};
    const input = Stream(u32).fromProducerWith(1, Helpers.produce, &state);
    var saved: Saved = .{};
    try runWithin(.{pipe(&input, .{ take(2), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, saved.slice());
    try std.testing.expect(state.stopped);
}

test "zero prefix does not start ordinary upstream production and collects empty once" {
    const Helpers = struct {
        fn produce(calls: *usize, _: *Emitter(u32)) void {
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    const input = Stream(u32).fromProducerWith(1, Helpers.produce, &calls);
    var saved: Saved = .{};
    try runWithin(.{pipe(&input, .{ take(0), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(@as(usize, 0), saved.len);
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "shared derived output serves short and long branches with one evaluation per item" {
    const Helpers = struct {
        var evaluations: std.atomic.Value(usize) = .init(0);
        fn twice(value: u32) u32 {
            _ = evaluations.fetchAdd(1, .monotonic);
            return value * 2;
        }
    };
    Helpers.evaluations.store(0, .monotonic);
    var input: [100]u32 = undefined;
    for (&input, 0..) |*value, i| value.* = @intCast(i);
    const shared = pipe(&input, .{each(Helpers.twice)});
    var short: Saved = .{};
    var whole: Saved = .{};
    try runWithin(.{
        pipe(&shared, .{ take(2), collectThenWith(&short, Saved.copy) }),
        pipe(&shared, .{collectThenWith(&whole, Saved.copy)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, short.slice());
    try std.testing.expectEqual(@as(usize, 100), whole.len);
    try std.testing.expectEqual(@as(usize, 100), Helpers.evaluations.load(.monotonic));
}

test "retirement crosses an exclusive derived chain without blocking a sibling source reader" {
    const Helpers = struct {
        fn twice(value: u32) u32 {
            return value * 2;
        }
        fn nonzero(value: u32) bool {
            return value != 0;
        }
    };
    var input: [100]u32 = undefined;
    for (&input, 0..) |*value, i| value.* = @intCast(i);
    const derived = pipe(&input, .{ each(Helpers.twice), filter(Helpers.nonzero), maxItems(100) });
    var short: Saved = .{};
    var whole: Saved = .{};
    try runWithin(.{
        pipe(&derived, .{ take(2), collectThenWith(&short, Saved.copy) }),
        pipe(&input, .{collectThenWith(&whole, Saved.copy)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, short.slice());
    try std.testing.expectEqualSlices(u32, &input, whole.slice());
}

test "a cold exclusive chain retires at zero without invoking transforms" {
    const Helpers = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn visit(value: u32) u32 {
            _ = calls.fetchAdd(1, .monotonic);
            return value;
        }
    };
    Helpers.calls.store(0, .monotonic);
    const input = [_]u32{ 1, 2, 3, 4 };
    const derived = pipe(&input, .{ each(Helpers.visit), takeLast(2) });
    var empty: Saved = .{};
    var whole: Saved = .{};
    try runWithin(.{
        pipe(&derived, .{ take(0), collectThenWith(&empty, Saved.copy) }),
        pipe(&input, .{collectThenWith(&whole, Saved.copy)}),
    });
    try std.testing.expectEqual(@as(usize, 0), Helpers.calls.load(.monotonic));
    try std.testing.expectEqualSlices(u32, &input, whole.slice());
}

test "prefix after repeated merge edges retires both edges while a sibling continues" {
    const input = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const merged = merge(.{ &input, &input });
    var short: Saved = .{};
    var whole: Saved = .{};
    try runWithin(.{
        pipe(&merged, .{ take(2), collectThenWith(&short, Saved.copy) }),
        pipe(&input, .{collectThenWith(&whole, Saved.copy)}),
    });
    try std.testing.expectEqual(@as(usize, 2), short.len);
    try std.testing.expectEqualSlices(u32, &input, whole.slice());
}

test "diamond prefixes retire concurrently while a shared sibling drains" {
    const State = struct {
        prefixes: std.atomic.Value(usize) = .init(0),
        both_prefixes: std.Io.Event = .unset,
        calls: std.atomic.Value(usize) = .init(0),
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            _ = state.calls.fetchAdd(1, .monotonic);
            for (0..100) |i| try output.push(@intCast(i));
        }
        fn same(value: u32) u32 {
            return value;
        }
        fn accept(_: u32) bool {
            return true;
        }
        fn prefix(state: *State, input: []const u32) !void {
            try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, input);
            if (state.prefixes.fetchAdd(1, .acq_rel) == 1) state.both_prefixes.set(io);
            // Release both finalizers together, before either closes its edge.
            try state.both_prefixes.wait(io);
        }
    };
    for (0..16) |_| {
        var state: State = .{};
        const source = Stream(u32).fromProducerWith(1, Helpers.produce, &state);
        const shared = pipe(&source, .{each(Helpers.same)});
        const left = pipe(&shared, .{each(Helpers.same)});
        const right = pipe(&shared, .{filter(Helpers.accept)});
        const diamond = merge(.{ &left, &right });
        var whole: Saved = .{};
        var merged: Saved = .{};
        try runWithin(.{
            pipe(&left, .{ take(2), collectThenWith(&state, Helpers.prefix) }),
            pipe(&right, .{ take(2), collectThenWith(&state, Helpers.prefix) }),
            pipe(&diamond, .{ take(2), collectThenWith(&merged, Saved.copy) }),
            pipe(&source, .{collectThenWith(&whole, Saved.copy)}),
        });
        try std.testing.expectEqual(@as(usize, 1), state.calls.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 2), merged.len);
        try std.testing.expectEqual(@as(usize, 100), whole.len);
        for (whole.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

test "unused idle merge input stops while an unrelated flow still requires progress" {
    const State = struct {
        idle_entered: std.Io.Event = .unset,
        idle_stopped: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn first(state: *State, output: *Emitter(u32)) !void {
            try state.idle_entered.wait(output.io);
            try output.push(7);
            try state.gate.wait(output.io);
        }
        fn idle(state: *State, output: *Emitter(u32)) !void {
            defer state.idle_stopped.set(output.io);
            state.idle_entered.set(output.io);
            try state.gate.wait(output.io);
        }
        fn remaining(state: *State, output: *Emitter(u32)) !void {
            try state.idle_stopped.wait(output.io);
            try output.push(9);
        }
    };
    var state: State = .{};
    const first = Stream(u32).fromProducerWith(1, Helpers.first, &state);
    const idle = Stream(u32).fromProducerWith(1, Helpers.idle, &state);
    const remaining = Stream(u32).fromProducerWith(1, Helpers.remaining, &state);
    const merged = merge(.{ &first, &idle });
    var short: Saved = .{};
    var other: Saved = .{};
    try runWithin(.{
        pipe(&merged, .{ take(1), collectThenWith(&short, Saved.copy) }),
        pipe(&remaining, .{collectThenWith(&other, Saved.copy)}),
    });
    try std.testing.expectEqualSlices(u32, &.{7}, short.slice());
    try std.testing.expectEqualSlices(u32, &.{9}, other.slice());
}

test "normal prefix completion flushes a partial batch and publishes a retained suffix" {
    const input = [_]u32{ 1, 2, 3, 4, 5 };
    var batch: Saved = .{};
    var suffix: Saved = .{};
    try runWithin(.{
        pipe(&input, .{ take(3), batchThenWith(4, &batch, Saved.copy) }),
        pipe(&input, .{ take(3), takeLast(2), collectThenWith(&suffix, Saved.copy) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, batch.slice());
    try std.testing.expectEqual(@as(usize, 1), batch.calls);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, suffix.slice());
}

test "errors before cutoff fail collection but errors beyond cutoff are not probed" {
    const Cursor = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.calls += 1;
            if (self.calls > 2) return error.Broken;
            return @intCast(self.calls);
        }
    };
    var cursor: Cursor = .{};
    var saved: Saved = .{};
    const source = fromIterator(&cursor);
    try runWithin(.{pipe(&source, .{ take(2), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, saved.slice());
    // run-backed forwarding can prefetch the error; prefix success is still
    // decided without an end/error probe after its second delivered item.
    cursor.calls = 0;
    saved.calls = 0;
    try std.testing.expectError(error.Broken, runWithin(.{
        pipe(&source, .{ take(3), collectThenWith(&saved, Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "observer prefix retirement keeps state publication and sampling alive" {
    const State = struct {
        observer_done: std.Io.Event = .unset,
        replacement_seen: std.Io.Event = .unset,
        sampled: u32 = 0,
        observations: usize = 0,
    };
    const Helpers = struct {
        fn updates(state: *State, output: *Emitter(u32)) !void {
            try state.observer_done.wait(output.io);
            // Progress beyond one queued update requires the family to keep
            // consuming/committing after its only observer has retired.
            for (42..45) |value| try output.push(@intCast(value));
            state.replacement_seen.set(output.io);
        }
        fn observed(state: *State, _: []const u32) void {
            state.observations += 1;
            state.observer_done.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.replacement_seen.wait(output.io);
            try output.push(1);
        }
        fn sample(state: *State, value: @Tuple(&.{ u8, u32 })) void {
            state.sampled = value[1];
        }
    };
    var state: State = .{};
    const updates = Stream(u32).fromProducerWith(1, Helpers.updates, &state);
    const current = pipe(&updates, .{hold(@as(u32, 0))});
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    try runWithin(.{
        pipe(values(&current), .{ take(1), collectThenWith(&state, Helpers.observed) }),
        pipe(&requests, .{ withLatestFrom(&current), forEachWith(&state, Helpers.sample) }),
    });
    try std.testing.expectEqual(@as(usize, 1), state.observations);
    try std.testing.expect(state.sampled >= 42 and state.sampled <= 44);
}

test "active signal source errors still fail after its observation prefix ends" {
    const State = struct {
        observed: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn updates(state: *State, output: *Emitter(u32)) !void {
            try state.observed.wait(output.io);
            return error.StateBroken;
        }
        fn observer(state: *State, _: []const u32) void {
            state.observed.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.gate.wait(output.io);
        }
        fn sample(_: @Tuple(&.{ u8, u32 })) void {}
    };
    var state: State = .{};
    const updates = Stream(u32).fromProducerWith(1, Helpers.updates, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&updates, .{hold(@as(u32, 0))});
    try std.testing.expectError(error.StateBroken, runWithin(.{
        pipe(values(&current), .{ take(1), collectThenWith(&state, Helpers.observer) }),
        pipe(&requests, .{ withLatestFrom(&current), forEach(Helpers.sample) }),
    }));
}

test "different cutoff schedules preserve live siblings and join the last producer" {
    const State = struct { stopped: bool = false };
    const Helpers = struct {
        fn produce(state: *State, output: *Emitter(u32)) !void {
            defer state.stopped = true;
            var value: u32 = 0;
            while (true) : (value += 1) try output.push(value);
        }
    };
    for (0..24) |round| {
        var state: State = .{};
        const input = Stream(u32).fromProducerWith(1, Helpers.produce, &state);
        var a: Saved = .{};
        var b: Saved = .{};
        var c: Saved = .{};
        const first = round % 4;
        const second = 4 + round % 4;
        try runWithin(.{
            pipe(&input, .{ take(first), collectThenWith(&a, Saved.copy) }),
            pipe(&input, .{ take(second), collectThenWith(&b, Saved.copy) }),
            pipe(&input, .{ take(10), collectThenWith(&c, Saved.copy) }),
        });
        try std.testing.expectEqual(first, a.len);
        try std.testing.expectEqual(second, b.len);
        try std.testing.expectEqual(@as(usize, 10), c.len);
        for (c.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
        try std.testing.expectEqualSlices(u32, c.slice()[0..a.len], a.slice());
        try std.testing.expectEqualSlices(u32, c.slice()[0..b.len], b.slice());
        try std.testing.expect(state.stopped);
    }
}

test "callback failure remains failure rather than successful prefix completion" {
    const Helpers = struct {
        fn fail(_: u32) error{EffectFailed}!void {
            return error.EffectFailed;
        }
    };
    const input = [_]u32{ 1, 2, 3 };
    try std.testing.expectError(error.EffectFailed, runWithin(.{
        pipe(&input, .{ take(2), forEach(Helpers.fail) }),
    }));
}

test "take and maxItems distinguish successful cutoff from excess validation" {
    const input = [_]u32{ 1, 2, 3 };
    var saved: Saved = .{};
    try runWithin(.{pipe(&input, .{ take(2), maxItems(2), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, saved.slice());
    try runWithin(.{pipe(&input, .{ maxItems(2), take(2), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectError(error.TooManyItems, runWithin(.{
        pipe(&input, .{ maxItems(1), take(2), collectThenWith(&saved, Saved.copy) }),
    }));
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const input = [_]u32{ 1, 2, 3, 4, 5 };
    const shared = pipe(&input, .{take(4)});
    var a: Saved = .{};
    var b: Saved = .{};
    var c: Saved = .{};
    // Keep the injected allocator exclusively in deterministic preparation;
    // accumulation allocations in concurrent consumers are covered elsewhere.
    try run(gpa, io, .{
        pipe(&shared, .{ take(1), forEachWith(&a, Saved.append) }),
        pipe(&shared, .{ take(3), forEachWith(&b, Saved.append) }),
        pipe(&shared, .{forEachWith(&c, Saved.append)}),
    });
    try std.testing.expectEqualSlices(u32, &.{1}, a.slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, b.slice());
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, c.slice());
}

test "preparation allocation failures clean up retained edge metadata and allow retry" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
