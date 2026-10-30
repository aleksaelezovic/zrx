const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const merge = zrx.merge;
const each = zrx.each;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const fromIterator = zrx.fromIterator;
const readFrom = zrx.readFrom;
const forEachWith = zrx.forEachWith;
const collectThenWith = zrx.collectThenWith;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

const Origin = enum { a, b, c };
const Event = struct { origin: Origin, number: u32 };
const Saved = struct {
    values: [32]Event = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn append(self: *@This(), value: Event) !void {
        if (self.len == self.values.len) return error.NoSpaceLeft;
        self.values[self.len] = value;
        self.len += 1;
    }
    fn copy(self: *@This(), values: []const Event) !void {
        if (values.len > self.values.len) return error.NoSpaceLeft;
        @memcpy(self.values[0..values.len], values);
        self.len = values.len;
        self.calls += 1;
    }
    fn slice(self: *@This()) []const Event {
        return self.values[0..self.len];
    }
};

const left = [_]Event{
    .{ .origin = .a, .number = 1 },
    .{ .origin = .a, .number = 2 },
    .{ .origin = .a, .number = 3 },
};
const right = [_]Event{
    .{ .origin = .b, .number = 1 },
    .{ .origin = .b, .number = 2 },
};

fn expectOrder(values: []const Event, origin: Origin, count: u32) !void {
    var next: u32 = 1;
    for (values) |value| {
        if (value.origin != origin) continue;
        try std.testing.expectEqual(next, value.number);
        next += 1;
    }
    try std.testing.expectEqual(count + 1, next);
}

test "merge is resource-free and preserves each finite input subsequence" {
    const empty = [_]Event{};
    const combined = comptime merge(.{ &left, &right, &empty });
    try std.testing.expect(!@hasDecl(@TypeOf(combined), "deinit"));
    try std.testing.expect(!@hasDecl(@TypeOf(combined), "iterator"));
    var saved: Saved = .{};
    const flow = pipe(&combined, .{collectThenWith(&saved, Saved.copy)});
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 5), saved.len);
    try expectOrder(saved.slice(), .a, 3);
    try expectOrder(saved.slice(), .b, 2);
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "single empty and nested merge declarations complete normally" {
    const empty = [_]Event{};
    var saved: Saved = .{};
    const one = merge(.{&left});
    try run(allocator, io, .{pipe(&one, .{collectThenWith(&saved, Saved.copy)})});
    try std.testing.expectEqualSlices(Event, &left, saved.slice());
    const none = merge(.{ &empty, &empty });
    try run(allocator, io, .{pipe(&none, .{collectThenWith(&saved, Saved.copy)})});
    try std.testing.expectEqual(@as(usize, 0), saved.len);
    const first = merge(.{ &left, &right });
    const third = [_]Event{.{ .origin = .c, .number = 1 }};
    const nested = merge(.{ &first, &third });
    try run(allocator, io, .{pipe(&nested, .{collectThenWith(&saved, Saved.copy)})});
    try std.testing.expectEqual(@as(usize, 6), saved.len);
    try expectOrder(saved.slice(), .a, 3);
    try expectOrder(saved.slice(), .b, 2);
    try expectOrder(saved.slice(), .c, 1);
}

test "conventional iterators and standard queue adapters remain deferred merge inputs" {
    const Cursor = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) ?Event {
            self.calls += 1;
            return if (self.calls == 1) .{ .origin = .c, .number = 1 } else null;
        }
    };
    var cursor: Cursor = .{};
    var storage: [1]Event = undefined;
    var queue: std.Io.Queue(Event) = .init(&storage);
    try queue.putOne(io, .{ .origin = .b, .number = 1 });
    queue.close(io);
    const combined = merge(.{ &left, fromIterator(&cursor), readFrom(io, &queue) });
    var saved: Saved = .{};
    try std.testing.expectEqual(@as(usize, 0), cursor.calls);
    try run(allocator, io, .{pipe(&combined, .{collectThenWith(&saved, Saved.copy)})});
    try std.testing.expectEqual(@as(usize, 5), saved.len);
    try std.testing.expectEqual(@as(usize, 2), cursor.calls);
    try expectOrder(saved.slice(), .a, 3);
    try expectOrder(saved.slice(), .b, 1);
    try expectOrder(saved.slice(), .c, 1);
}

const Producer = struct {
    calls: std.atomic.Value(usize) = .init(0),
    origin: Origin,
    fn produce(self: *@This(), output: *Emitter(Event)) !void {
        _ = self.calls.fetchAdd(1, .monotonic);
        for (1..4) |number| try output.push(.{ .origin = self.origin, .number = @intCast(number) });
    }
};

test "unselected merges neither activate inputs nor retain shared source capacity" {
    const Helpers = struct {
        fn forbidden(_: *Emitter(Event)) void {
            @panic("unselected merge activated its input");
        }
    };
    var producer: Producer = .{ .origin = .a };
    const source = Stream(Event).fromProducerWith(1, Producer.produce, &producer);
    const unused_source = Stream(Event).fromProducer(1, Helpers.forbidden);
    const unused = merge(.{ &source, &unused_source });
    var ignored: Saved = .{};
    _ = pipe(&unused, .{collectThenWith(&ignored, Saved.copy)});
    var selected: Saved = .{};
    try run(allocator, io, .{pipe(&source, .{collectThenWith(&selected, Saved.copy)})});
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    try std.testing.expectEqual(@as(usize, 1), producer.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), ignored.calls);
}

test "two consumers of one merge see the same interleaving and fresh runs restart producers" {
    var a: Producer = .{ .origin = .a };
    var b: Producer = .{ .origin = .b };
    const source_a = Stream(Event).fromProducerWith(1, Producer.produce, &a);
    const source_b = Stream(Event).fromProducerWith(1, Producer.produce, &b);
    const combined = merge(.{ &source_a, &source_b });
    var whole: Saved = .{};
    var per_item: Saved = .{};
    const first = pipe(&combined, .{collectThenWith(&whole, Saved.copy)});
    const second = pipe(&combined, .{forEachWith(&per_item, Saved.append)});
    try std.testing.expectEqual(@as(usize, 0), a.calls.load(.monotonic));
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqual(@as(usize, 6), whole.len);
    try std.testing.expectEqualSlices(Event, whole.slice(), per_item.slice());
    try expectOrder(whole.slice(), .a, 3);
    try expectOrder(whole.slice(), .b, 3);
    try std.testing.expectEqual(@as(usize, 1), a.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), b.calls.load(.monotonic));
    per_item.len = 0;
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqualSlices(Event, whole.slice(), per_item.slice());
    try std.testing.expectEqual(@as(usize, 2), a.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), b.calls.load(.monotonic));
}

test "repeating an input reference creates multiple edges not multiple producer calls" {
    var producer: Producer = .{ .origin = .a };
    const source = Stream(Event).fromProducerWith(1, Producer.produce, &producer);
    const combined = merge(.{ &source, &source, &source });
    var saved: Saved = .{};
    try run(allocator, io, .{pipe(&combined, .{collectThenWith(&saved, Saved.copy)})});
    try std.testing.expectEqual(@as(usize, 1), producer.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 9), saved.len);
    var counts: [3]usize = @splat(0);
    for (saved.slice()) |value| counts[value.number - 1] += 1;
    try std.testing.expectEqualSlices(usize, &.{ 3, 3, 3 }, &counts);
}

test "shared source and retained branch progress together through merge" {
    var producer: Producer = .{ .origin = .a };
    const source = Stream(Event).fromProducerWith(1, Producer.produce, &producer);
    const tail = pipe(&source, .{takeLast(1)});
    // Retention waits for end while the other reader must keep draining.
    const combined = merge(.{ &tail, &source });
    var saved: Saved = .{};
    try run(allocator, io, .{pipe(&combined, .{ maxItems(4), collectThenWith(&saved, Saved.copy) })});
    try std.testing.expectEqual(@as(usize, 4), saved.len);
    var counts: [3]usize = @splat(0);
    for (saved.slice()) |value| counts[value.number - 1] += 1;
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 2 }, &counts);
    try std.testing.expectEqual(@as(usize, 1), producer.calls.load(.monotonic));
}

test "an empty open input does not block a ready input and merge waits for all ends" {
    const State = struct {
        started: std.Io.Event = .unset,
        observed: std.Io.Event = .unset,
        finish: std.Io.Event = .unset,
        collected: std.atomic.Value(bool) = .init(false),
        saved: Saved = .{},
    };
    const Helpers = struct {
        fn blocked(state: *State, output: *Emitter(Event)) !void {
            state.started.set(io);
            try state.finish.wait(io);
            try output.push(.{ .origin = .b, .number = 1 });
        }
        fn ready(state: *State, output: *Emitter(Event)) !void {
            try state.started.wait(io);
            try output.push(.{ .origin = .a, .number = 1 });
        }
        fn observe(state: *State, value: Event) void {
            if (value.origin == .a) state.observed.set(io);
        }
        fn collection(state: *State, values: []const Event) !void {
            try state.saved.copy(values);
            state.collected.store(true, .release);
        }
        fn execute(state: *State) !void {
            const a = Stream(Event).fromProducerWith(1, blocked, state);
            const b = Stream(Event).fromProducerWith(1, ready, state);
            const combined = merge(.{ &a, &b });
            try run(allocator, io, .{
                pipe(&combined, .{forEachWith(state, observe)}),
                pipe(&combined, .{collectThenWith(state, collection)}),
            });
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.observed.wait(io);
    try std.testing.expect(!state.collected.load(.acquire));
    state.finish.set(io);
    try task.await(io);
    try std.testing.expectEqual(@as(usize, 2), state.saved.len);
    try std.testing.expect(state.collected.load(.acquire));
}

test "explicit type conversion before merge and item error optional data are preserved" {
    const Data = error{Bad}!?u32;
    const Helpers = struct {
        fn wrap(value: u8) Data {
            return value;
        }
        fn verify(calls: *usize, values: []const Data) !void {
            var bad: usize = 0;
            var absent: usize = 0;
            var good: usize = 0;
            for (values) |value| {
                const optional = value catch |err| {
                    try std.testing.expectEqual(error.Bad, err);
                    bad += 1;
                    continue;
                };
                if (optional) |number| {
                    try std.testing.expectEqual(@as(u32, 7), number);
                    good += 1;
                } else absent += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), bad);
            try std.testing.expectEqual(@as(usize, 1), absent);
            try std.testing.expectEqual(@as(usize, 1), good);
            calls.* += 1;
        }
    };
    const a = [_]Data{ error.Bad, null };
    const b = [_]u8{7};
    const converted = pipe(&b, .{each(Helpers.wrap)});
    const combined = merge(.{ &a, &converted });
    var calls: usize = 0;
    try run(allocator, io, .{pipe(&combined, .{collectThenWith(&calls, Helpers.verify)})});
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "an input failure cancels blocked peers and suppresses collection" {
    const State = struct {
        entered: std.Io.Event = .unset,
        observed: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
        effects: usize = 0,
    };
    const Helpers = struct {
        fn blocked(state: *State, _: *Emitter(Event)) !void {
            defer state.finished.store(true, .release);
            state.entered.set(io);
            try state.gate.wait(io);
        }
        fn broken(state: *State, output: *Emitter(Event)) !void {
            try state.entered.wait(io);
            try output.push(.{ .origin = .a, .number = 1 });
            try state.observed.wait(io);
            return error.Broken;
        }
        fn observe(state: *State, _: Event) void {
            state.effects += 1;
            state.observed.set(io);
        }
    };
    var state: State = .{};
    const a = Stream(Event).fromProducerWith(1, Helpers.blocked, &state);
    const b = Stream(Event).fromProducerWith(1, Helpers.broken, &state);
    const combined = merge(.{ &a, &b });
    var saved: Saved = .{};
    try std.testing.expectError(error.Broken, run(allocator, io, .{
        pipe(&combined, .{collectThenWith(&saved, Saved.copy)}),
        pipe(&combined, .{forEachWith(&state, Helpers.observe)}),
    }));
    try std.testing.expect(state.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try std.testing.expectEqual(@as(usize, 1), state.effects);
}

test "a producer Closed error is not normalized to successful input end" {
    const Helpers = struct {
        fn closed(_: *Emitter(Event)) error{Closed}!void {
            return error.Closed;
        }
    };
    const source = Stream(Event).fromProducer(1, Helpers.closed);
    const empty = [_]Event{};
    const combined = merge(.{ &source, &empty });
    var saved: Saved = .{};
    try std.testing.expectError(error.Closed, run(allocator, io, .{
        pipe(&combined, .{collectThenWith(&saved, Saved.copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "racing source failures preserve an observed input error not cleanup cancellation" {
    const State = struct {
        entered: std.atomic.Value(usize) = .init(0),
        both: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn ready(state: *State) !void {
            if (state.entered.fetchAdd(1, .acq_rel) == 1) state.both.set(io);
            try state.both.wait(io);
        }
        fn a(state: *State, _: *Emitter(Event)) !void {
            try ready(state);
            return error.Left;
        }
        fn b(state: *State, _: *Emitter(Event)) !void {
            try ready(state);
            return error.Right;
        }
    };
    var state: State = .{};
    const a = Stream(Event).fromProducerWith(1, Helpers.a, &state);
    const b = Stream(Event).fromProducerWith(1, Helpers.b, &state);
    const combined = merge(.{ &a, &b });
    var saved: Saved = .{};
    run(allocator, io, .{pipe(&combined, .{collectThenWith(&saved, Saved.copy)})}) catch |err| {
        try std.testing.expect(err == error.Left or err == error.Right);
        try std.testing.expectEqual(@as(usize, 0), saved.calls);
        return;
    };
    return error.ExpectedInputFailure;
}

const BlockingState = struct {
    started: std.atomic.Value(usize) = .init(0),
    finished: std.atomic.Value(usize) = .init(0),
    both_started: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    saved: Saved = .{},
};

fn markStarted(state: *BlockingState) void {
    if (state.started.fetchAdd(1, .acq_rel) == 1) state.both_started.set(io);
}

test "terminal failure cancels forwarding workers and hot input producers" {
    const Helpers = struct {
        fn source(state: *BlockingState, output: *Emitter(Event)) !void {
            markStarted(state);
            defer _ = state.finished.fetchAdd(1, .acq_rel);
            while (true) try output.push(.{ .origin = .a, .number = 1 });
        }
        fn reject(state: *BlockingState, _: Event) !void {
            try state.both_started.wait(io);
            return error.Stop;
        }
    };
    var state: BlockingState = .{};
    const source = Stream(Event).fromProducerWith(1, Helpers.source, &state);
    // Independent description copies activate two producer instances.
    const combined = merge(.{ source, source });
    try std.testing.expectError(error.Stop, run(allocator, io, .{
        pipe(&combined, .{forEachWith(&state, Helpers.reject)}),
    }));
    try std.testing.expectEqual(@as(usize, 2), state.finished.load(.acquire));
}

test "parent cancellation joins merge workers and producers waiting on other Io" {
    const Helpers = struct {
        fn source(state: *BlockingState, _: *Emitter(Event)) !void {
            markStarted(state);
            defer _ = state.finished.fetchAdd(1, .acq_rel);
            try state.gate.wait(io);
        }
        fn execute(state: *BlockingState) !void {
            const source_description = Stream(Event).fromProducerWith(1, source, state);
            const combined = merge(.{ source_description, source_description });
            try run(allocator, io, .{pipe(&combined, .{collectThenWith(&state.saved, Saved.copy)})});
        }
    };
    var state: BlockingState = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.both_started.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expectEqual(@as(usize, 2), state.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), state.saved.calls);
}

test "merge worker startup failure occurs before input producer activation" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(3) });
    defer backend.deinit();
    var a: Producer = .{ .origin = .a };
    var b: Producer = .{ .origin = .b };
    const source_a = Stream(Event).fromProducerWith(1, Producer.produce, &a);
    const source_b = Stream(Event).fromProducerWith(1, Producer.produce, &b);
    const combined = merge(.{ &source_a, &source_b });
    var saved: Saved = .{};
    const flow = pipe(&combined, .{collectThenWith(&saved, Saved.copy)});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{flow}));
    try std.testing.expectEqual(@as(usize, 0), a.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), b.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try run(allocator, io, .{flow});
    try std.testing.expectEqual(@as(usize, 6), saved.len);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const combined = merge(.{ &left, &right, &left });
    var saved: Saved = .{};
    run(gpa, io, .{pipe(&combined, .{ takeLast(3), collectThenWith(&saved, Saved.copy) })}) catch |err| {
        if (err == error.OutOfMemory) try std.testing.expectEqual(@as(usize, 0), saved.calls);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "allocation failures clean up merge inputs transport retention and collection" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
