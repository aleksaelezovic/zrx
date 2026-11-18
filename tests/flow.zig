//! queue, branch and route.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const fromProducer = zrx.fromProducer;
const resource = zrx.resource;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const fold = zrx.fold;
const take = zrx.take;
const queue = zrx.queue;
const concurrent = zrx.concurrent;
const branch = zrx.branch;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const forEach = zrx.forEach;
const drain = zrx.drain;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

fn double(value: u32) u32 {
    return value * 2;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn add(sum: u32, value: u32) u32 {
    return sum + value;
}

// --- queue ----------------------------------------------------------------

test "a queue delivers every item in order" {
    var seen: Numbers = .{};
    const capacity: usize = 8;
    try program(range(u32, 0, 100), pipe(.{ map(double), queue(capacity), filter(isEven), forEach(record) })).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 100), seen.len);
    for (seen.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i * 2)), value);
}

test "a borrowed queue can reuse the same slots on a later run" {
    var slots: [2]u32 = undefined;
    var first: Numbers = .{};
    var second: Numbers = .{};
    const work = program(range(u32, 0, 5), pipe(.{ queue(&slots), forEach(record) }));

    try work.run(.{ io, &first });
    try work.run(.{ io, &second });
    try first.expect(&.{ 0, 1, 2, 3, 4 });
    try second.expect(first.slice());
}

fn slowly(clock: std.Io, value: u32) !u32 {
    try clock.sleep(.fromMicroseconds(200), .awake);
    return value;
}

test "a full queue makes the producer wait instead of dropping items" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 40), pipe(.{ queue(1), map(slowly), forEach(record) })).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 40), seen.len);
    for (seen.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
}

test "the stream end waits for the queue to drain, then finishes what follows it" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 101), pipe(.{ queue(4), fold(@as(u32, 0), add), forEach(record) })).run(.{ io, &seen });
    try seen.expect(&.{5050});
}

fn failAtFive(value: u32) error{Five}!u32 {
    if (value == 5) return error.Five;
    return value;
}

test "an error after a queue fails the run" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 1000), pipe(.{ queue(2), map(failAtFive), forEach(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

test "an error before a queue stops its consumer" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 1000), pipe(.{ map(failAtFive), queue(2), forEach(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try std.testing.expect(seen.len <= 5);
}

test "take after a queue stops an endless source" {
    var seen: Numbers = .{};
    try program(range(u32, 0, std.math.maxInt(u32)), pipe(.{ queue(4), take(3), forEach(record) })).run(.{ io, &seen });
    try seen.expect(&.{ 0, 1, 2 });
}

test "queues compose: two boundaries in one pipe" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 50), pipe(.{ queue(2), map(double), queue(2), fold(@as(u32, 0), add), forEach(record) })).run(.{ io, &seen });
    try seen.expect(&.{2450});
}

// --- concurrent -----------------------------------------------------------

const PoolOrder = struct {
    release_first: std.Io.Event = .unset,

    fn work(clock: std.Io, state: *PoolOrder, item: u32) !u32 {
        if (item == 0) try state.release_first.wait(clock);
        return item * 2;
    }

    fn collect(clock: std.Io, state: *PoolOrder, seen: *Numbers, item: u32) void {
        seen.add(item);
        if (item == 2) state.release_first.set(clock);
    }
};

test "concurrent workers overlap and emit without waiting for input order" {
    var state: PoolOrder = .{};
    var seen: Numbers = .{};
    try program(range(u32, 0, 2), .{ concurrent(2, .{map(PoolOrder.work)}), forEach(PoolOrder.collect) }).run(.{ io, &state, &seen });
    try seen.expect(&.{ 2, 0 });
}

const PoolSerial = struct {
    first_entered: std.Io.Event = .unset,
    release_first: std.Io.Event = .unset,
    active: std.atomic.Value(bool) = .init(false),
    overlapped: std.atomic.Value(bool) = .init(false),

    fn work(clock: std.Io, state: *PoolSerial, item: u32) !u32 {
        if (item == 1) {
            try state.first_entered.wait(clock);
            support.GateWait.thread.store(std.Thread.getCurrentId(), .seq_cst);
        }
        return item;
    }

    fn collect(clock: std.Io, state: *PoolSerial, item: u32) !void {
        if (item == 0) {
            state.active.store(true, .seq_cst);
            state.first_entered.set(clock);
            try state.release_first.wait(clock);
            state.active.store(false, .seq_cst);
        } else {
            state.overlapped.store(state.active.load(.seq_cst), .seq_cst);
            state.release_first.set(clock);
        }
    }
};

test "concurrent serializes downstream pushes while another worker is ready" {
    var state: PoolSerial = .{};
    const clock = support.GateWait.over(io, &state.release_first);
    try program(range(u32, 0, 2), .{ concurrent(2, .{map(PoolSerial.work)}), forEach(PoolSerial.collect) }).run(.{ clock, &state });
    try std.testing.expect(support.GateWait.waiting.load(.seq_cst));
    try std.testing.expect(!state.overlapped.load(.seq_cst));
}

test "concurrent shares every item once and rejoins a single fold" {
    var seen: Numbers = .{};
    const worker = pipe(.{ map(double), filter(isEven) });
    try program(range(u32, 1, 101), .{ concurrent(4, worker), forEach(record) }).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 100), seen.len);
    var received: [100]bool = @splat(false);
    for (seen.slice()) |item| {
        try std.testing.expect(item >= 2 and item <= 200 and item % 2 == 0);
        const index = item / 2 - 1;
        try std.testing.expect(!received[index]);
        received[index] = true;
    }
    seen.len = 0;
    try program(range(u32, 1, 101), .{ concurrent(4, worker), fold(@as(u32, 0), add), forEach(record) }).run(.{ io, &seen });
    try seen.expect(&.{10100});
}

fn countItem(count: u32, _: u32) u32 {
    return count + 1;
}

test "each concurrent worker owns its limits and finishes its state once on every run" {
    var seen: Numbers = .{};
    var counted: PoolCount = .{};
    const app = program(range(u32, 0, std.math.maxInt(u32)), .{
        concurrent(4, .{ take(2), tap(PoolCount.addOne), fold(@as(u32, 0), countItem) }),
        fold(@as(u32, 0), add),
        forEach(record),
    });
    try app.run(.{ io, &seen, &counted });
    try app.run(.{ io, &seen, &counted });
    try seen.expect(&.{ 8, 8 });
    try std.testing.expectEqual(@as(usize, 16), counted.count.load(.monotonic));
}

const PoolHalfway = struct {
    first_output: std.Io.Event = .unset,
    stopped: bool = false,
    handled: std.atomic.Value(usize) = .init(0),

    fn produce(stop: zrx.Stop, clock: std.Io, state: *PoolHalfway, out: anytype) !void {
        if (try out.push(1) == .done) return error.PrematureStop;
        try state.first_output.wait(clock);
        try std.testing.expect(!stop.requested());
        if (try out.push(2) == .done) return error.PrematureStop;
        try stop.wait(clock);
        state.stopped = true;
    }

    fn collect(clock: std.Io, state: *PoolHalfway, seen: *Numbers, item: u32) void {
        seen.add(item);
        state.first_output.set(clock);
    }

    fn took(state: *PoolHalfway, _: u32) void {
        _ = state.handled.fetchAdd(1, .monotonic);
    }
};

test "one completed concurrent worker leaves input open for the others" {
    var state: PoolHalfway = .{};
    var seen: Numbers = .{};
    try program(fromProducer(u32, PoolHalfway.produce), .{
        concurrent(2, .{ take(1), tap(PoolHalfway.took), fold(@as(u32, 0), countItem) }),
        forEach(PoolHalfway.collect),
    }).run(.{ io, &state, &seen });
    try seen.expect(&.{ 1, 1 });
    try std.testing.expect(state.stopped);
    try std.testing.expectEqual(@as(usize, 2), state.handled.load(.monotonic));
}

const PoolInputEnd = struct {
    returned: std.Io.Event = .unset,

    fn produce(clock: std.Io, state: *PoolInputEnd, out: anytype) !void {
        defer state.returned.set(clock);
        var item: u32 = 0;
        while (try out.push(item) == .more) : (item += 1) {}
    }

    fn awaitSource(clock: std.Io, state: *PoolInputEnd, item: u32) !u32 {
        try state.returned.wait(clock);
        return item;
    }
};

test "the last concurrent input loop retires before its final emission" {
    var state: PoolInputEnd = .{};
    var seen: Numbers = .{};
    try program(fromProducer(u32, PoolInputEnd.produce), .{
        concurrent(1, .{ take(1), fold(@as(u32, 0), countItem), map(PoolInputEnd.awaitSource) }),
        forEach(record),
    }).run(.{ io, &state, &seen });
    try seen.expect(&.{1});
}

const PoolStop = struct {
    source_returned: std.Io.Event = .unset,
    worker_waiting: std.Io.Event = .unset,

    fn produce(stop: zrx.Stop, clock: std.Io, state: *PoolStop, out: anytype) !void {
        if (try out.push(0) == .done) return error.PrematureStop;
        if (try out.push(1) == .done) return error.PrematureStop;
        try stop.wait(clock);
        state.source_returned.set(clock);
    }

    fn awaitSource(clock: std.Io, state: *PoolStop, item: u32) !u32 {
        try state.source_returned.wait(clock);
        return item;
    }

    fn work(clock: std.Io, state: *PoolStop, item: u32) !u32 {
        if (item == 0) {
            state.worker_waiting.set(clock);
            return awaitSource(clock, state, item);
        }
        try state.worker_waiting.wait(clock);
        return item;
    }
};

test "concurrent worker limits wake the producer before their final emissions" {
    var state: PoolStop = .{};
    var seen: Numbers = .{};
    try program(fromProducer(u32, PoolStop.produce), .{
        concurrent(2, .{ take(1), fold(@as(u32, 0), countItem), map(PoolStop.awaitSource) }),
        fold(@as(u32, 0), add),
        forEach(record),
    }).run(.{ io, &state, &seen });
    try seen.expect(&.{2});
}

test "a concurrent continuation limit wakes the producer while a worker is still running" {
    var state: PoolStop = .{};
    var seen: Numbers = .{};
    try program(fromProducer(u32, PoolStop.produce), .{
        concurrent(2, .{map(PoolStop.work)}),
        take(1),
        forEach(record),
    }).run(.{ io, &state, &seen });
    try seen.expect(&.{1});
}

test "empty input still finishes each concurrent worker and downstream once" {
    var seen: Numbers = .{};
    const clock = support.WorkersAfterWait.over(io);
    try program(range(u32, 0, 0), .{
        concurrent(3, .{fold(@as(u32, 7), add)}),
        fold(@as(u32, 0), add),
        forEach(record),
    }).run(.{ clock, &seen });
    try seen.expect(&.{21});
}

const PoolCount = struct {
    count: std.atomic.Value(usize) = .init(0),

    fn addOne(state: *PoolCount, _: u32) void {
        _ = state.count.fetchAdd(1, .monotonic);
    }
};

test "a concurrent worker pipe can terminate" {
    var state: PoolCount = .{};
    try program(range(u32, 0, 100), .{concurrent(4, .{forEach(PoolCount.addOne)})}).run(.{ io, &state });
    try std.testing.expectEqual(@as(usize, 100), state.count.load(.monotonic));
}

const PoolBarrier = struct {
    entered: std.atomic.Value(usize) = .init(0),
    all_entered: std.Io.Event = .unset,

    fn work(clock: std.Io, state: *PoolBarrier, item: u32) !u32 {
        if (state.entered.fetchAdd(1, .acq_rel) == 3) state.all_entered.set(clock);
        try state.all_entered.wait(clock);
        return item;
    }
};

test "concurrent starts the requested number of workers" {
    var state: PoolBarrier = .{};
    var seen: Numbers = .{};
    const clock = support.TaskStarts.over(io);
    try program(range(u32, 0, 100), .{ concurrent(4, .{map(PoolBarrier.work)}), fold(@as(u32, 0), add), forEach(record) }).run(.{ clock, &state, &seen });
    try seen.expect(&.{4950});
    try std.testing.expectEqual(@as(usize, 100), state.entered.load(.acquire));
    // The source, the coordinating boundary, and four workers for the run.
    try std.testing.expectEqual(@as(usize, 6), support.TaskStarts.count.load(.seq_cst));
}

const PoolWaiting = struct {
    entered: std.atomic.Value(usize) = .init(0),
    exited: std.atomic.Value(usize) = .init(0),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
    all_entered: std.Io.Event = .unset,

    fn work(clock: std.Io, state: *PoolWaiting, item: u32) !u32 {
        defer _ = state.exited.fetchAdd(1, .acq_rel);
        if (state.entered.fetchAdd(1, .acq_rel) == 3) state.all_entered.set(clock);
        try clock.sleep(.fromSeconds(3600), .awake);
        state.woke_by_itself.store(true, .release);
        return item;
    }

    fn run(clock: std.Io, state: *PoolWaiting) !void {
        try program(range(u32, 0, 4), .{ concurrent(4, .{map(work)}), drain() }).run(.{ clock, state });
    }
};

test "caller cancellation joins every concurrent worker" {
    var backend: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer backend.deinit();
    const clock = backend.io();
    var state: PoolWaiting = .{};
    var running = try clock.concurrent(PoolWaiting.run, .{ clock, &state });
    defer _ = running.cancel(clock) catch {};
    try state.all_entered.wait(clock);
    try std.testing.expectError(error.Canceled, running.cancel(clock));
    try std.testing.expectEqual(@as(usize, 4), state.exited.load(.acquire));
    try std.testing.expect(!state.woke_by_itself.load(.acquire));
}

test "concurrent fails when worker tasks cannot be started" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(2) });
    defer backend.deinit();
    var seen: Numbers = .{};
    const app = program(range(u32, 0, 10), .{ concurrent(4, .{map(double)}), forEach(record) });
    try std.testing.expectError(error.ConcurrencyUnavailable, app.run(.{ backend.io(), &seen }));
    try seen.expect(&.{});
}

fn ignoreFive(_: error{Five}, _: u32) void {}

test "recover inside a concurrent worker can handle an error from its downstream push" {
    var seen: Numbers = .{};
    try program(range(u32, 4, 7), .{
        concurrent(1, .{ zrx.recover(ignoreFive), map(same) }),
        map(failAtFive),
        forEach(record),
    }).run(.{ io, &seen });
    try seen.expect(&.{ 4, 6 });
}

test "a concurrent worker finish error fails the run without finishing downstream" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 0), .{
        concurrent(2, .{ fold(@as(u32, 5), add), map(failAtFive) }),
        fold(@as(u32, 0), add),
        forEach(record),
    }).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try seen.expect(&.{});
}

const StoppableSource = struct {
    waiting: std.Io.Event = .unset,
    left_finished: std.Io.Event = .unset,
    stopped: bool = false,
    wait_for_left: bool = false,
    finite: bool = false,

    fn produce(stop: zrx.Stop, clock: std.Io, state: *StoppableSource, out: anytype) !void {
        if (try out.push(1) == .done) return error.UnexpectedDone;
        if (state.wait_for_left) {
            try state.left_finished.wait(clock);
            try std.testing.expect(!stop.requested());
            if (try out.push(2) == .done) return error.UnexpectedDone;
            try std.testing.expect(!stop.requested());
        }
        if (state.finite) return;
        state.waiting.set(clock);
        try stop.wait(clock);
        state.stopped = true;
    }

    fn waitForSource(clock: std.Io, state: *StoppableSource, item: u32) !u32 {
        try state.waiting.wait(clock);
        return item;
    }

    fn leftFinished(clock: std.Io, state: *StoppableSource, _: u32) void {
        state.left_finished.set(clock);
    }

    fn waitForSecondPush(clock: std.Io, state: *StoppableSource, item: u32) !u32 {
        if (item == 2) try state.waiting.wait(clock);
        return item;
    }
};

test "a downstream limit wakes a producer without another item and all segments finish" {
    const source = fromProducer(u32, StoppableSource.produce);
    const end = pipe(.{ map(StoppableSource.waitForSource), take(1), mark(1), fold(@as(u32, 5), add), forEach(record) });
    const shapes = .{
        .{ mark(0), queue(1), end },
        pipe(.{ mark(0), queue(1), queue(1), end }),
        pipe(.{ mark(0), queue(1), map(StoppableSource.waitForSource), take(1), queue(1), mark(1), fold(@as(u32, 5), add), forEach(record) }),
        pipe(.{ mark(0), zrx.batchWithin(1, .fromSeconds(1)), zrx.flatten(), end }),
        pipe(.{ mark(0), branch(.{.{ queue(1), end }}) }),
        pipe(.{ mark(0), route(.{otherwise(.{ queue(1), end })}) }),
        pipe(.{ mark(0), concurrent(2, .{map(same)}), end }),
        pipe(.{ mark(0), concurrent(2, .{map(same)}), queue(1), end }),
        pipe(.{ mark(0), concurrent(1, .{end}) }),
    };
    inline for (shapes) |shape| {
        var state: StoppableSource = .{};
        var seen: Numbers = .{};
        var ticks: Ticks = .{};
        var upstream: Trace(0) = .{};
        var downstream: Trace(1) = .{};
        try program(source, shape).run(.{ io, &state, &seen, &ticks, &upstream, &downstream });
        try std.testing.expect(state.stopped);
        try seen.expect(&.{6});
        try upstream.events.expect("ipf");
        try downstream.events.expect("ipf");
    }
}

test "a shared producer keeps running until both queued consumers are done" {
    const left = pipe(.{ queue(1), take(1), fold(@as(u32, 0), add), forEach(StoppableSource.leftFinished) });
    const right = pipe(.{ queue(1), map(StoppableSource.waitForSecondPush), take(2), forEach(record) });
    const routed_right = pipe(.{ queue(1), map(StoppableSource.waitForSecondPush), take(1), forEach(record) });
    const shapes = .{
        pipe(.{branch(.{ left, right })}),
        pipe(.{route(.{ when(isEven, routed_right), otherwise(left) })}),
        pipe(.{branch(.{ pipe(.{branch(.{left})}), right })}),
        pipe(.{branch(.{ .{concurrent(1, .{ take(1), fold(@as(u32, 0), add), forEach(StoppableSource.leftFinished) })}, right })}),
    };
    inline for (shapes, 0..) |shape, i| {
        var state: StoppableSource = .{ .wait_for_left = true };
        var seen: Numbers = .{};
        try program(fromProducer(u32, StoppableSource.produce), shape).run(.{ io, &state, &seen });
        try std.testing.expect(state.stopped);
        try seen.expect(if (i == 1) &.{2} else &.{ 1, 2 });
    }
}

test "a live direct branch still receives items when a queued branch stops" {
    var state: StoppableSource = .{ .wait_for_left = true, .finite = true };
    var seen: Numbers = .{};
    const left = pipe(.{ queue(1), take(1), fold(@as(u32, 0), add), forEach(StoppableSource.leftFinished) });
    const work = pipe(.{branch(.{ left, pipe(.{forEach(record)}) })});
    try program(fromProducer(u32, StoppableSource.produce), work).run(.{ io, &state, &seen });
    try seen.expect(&.{ 1, 2 });
}

test "a branch that stopped synchronously no longer holds shared upstream open" {
    var state: StoppableSource = .{};
    var seen: Numbers = .{};
    const left = pipe(.{ take(1), queue(1), drain() });
    const right = pipe(.{ queue(1), map(StoppableSource.waitForSource), take(1), forEach(record) });
    const work = program(fromProducer(u32, StoppableSource.produce), pipe(.{branch(.{ left, right })}));
    try work.run(.{ io, &state, &seen });
    try std.testing.expect(state.stopped);
    try seen.expect(&.{1});
}

test "a finish error still fails the run after a downstream limit" {
    var state: StoppableSource = .{};
    const work = program(fromProducer(u32, StoppableSource.produce), pipe(.{
        queue(1), map(StoppableSource.waitForSource), take(1), queue(1), fold(@as(u32, 4), add), map(failAtFive), drain(),
    }));
    try std.testing.expectError(error.Five, work.run(.{ io, &state }));
}

const PendingInput = struct {
    ready: std.Io.Event = .unset,
    interrupted: bool = false,

    fn read(clock: std.Io, state: *PendingInput, source: *StoppableSource) std.Io.Cancelable!void {
        source.waiting.set(clock);
        state.ready.wait(clock) catch |err| {
            state.interrupted = true;
            return err;
        };
    }

    fn waitForStop(stop: zrx.Stop, clock: std.Io) std.Io.Cancelable!void {
        return stop.wait(clock);
    }

    fn produce(stop: zrx.Stop, clock: std.Io, pending: *PendingInput, source: *StoppableSource, out: anytype) !void {
        if (try out.push(1) == .done) return;

        const Result = union(enum) { input: std.Io.Cancelable!void, stop: std.Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(clock, &buffer);
        defer select.cancelDiscard();
        try select.concurrent(.input, read, .{ clock, pending, source });
        try select.concurrent(.stop, waitForStop, .{ stop, clock });
        switch (try select.await()) {
            .input => |result| {
                try result;
                return error.UnexpectedInput;
            },
            .stop => |result| try result,
        }
    }
};

test "a producer can stop a pending input wait without canceling its segment" {
    var pending: PendingInput = .{};
    var source: StoppableSource = .{};
    var seen: Numbers = .{};
    const work = pipe(.{ queue(1), map(StoppableSource.waitForSource), take(1), forEach(record) });
    try program(fromProducer(u32, PendingInput.produce), work).run(.{ io, &pending, &source, &seen });
    try std.testing.expect(pending.interrupted);
    try seen.expect(&.{1});
}

const MergedWait = struct {
    waiting: std.Io.Event = .unset,
    stopped: bool = false,

    fn idle(stop: zrx.Stop, clock: std.Io, state: *MergedWait, _: anytype) !void {
        state.waiting.set(clock);
        try stop.wait(clock);
        state.stopped = true;
    }

    fn waitForIdle(clock: std.Io, state: *MergedWait, value: u32) !u32 {
        try state.waiting.wait(clock);
        return value;
    }
};

test "a queued downstream limit wakes an idle producer inside merge" {
    var state: MergedWait = .{};
    var seen: Numbers = .{};
    const source = zrx.merge(.{ zrx.fromValue(@as(u32, 1)), fromProducer(u32, MergedWait.idle) });
    const work = pipe(.{ queue(1), map(MergedWait.waitForIdle), take(1), forEach(record) });
    try program(source, work).run(.{ io, &state, &seen });
    try std.testing.expect(state.stopped);
    try seen.expect(&.{1});
}

const StoppingInput = struct {
    stopping: std.Io.Event = .unset,

    fn produce(stop: zrx.Stop, clock: std.Io, state: *StoppingInput, out: anytype) !void {
        if (try out.push(1) == .done) return;
        try stop.wait(clock);
        state.stopping.set(clock);
        var released: std.Io.Event = .unset;
        try released.wait(clock);
    }

    fn run(clock: std.Io, state: *StoppingInput) !void {
        const work = pipe(.{ queue(1), take(1), drain() });
        return program(fromProducer(u32, produce), work).run(.{ clock, state });
    }
};

test "caller cancellation still interrupts a producer responding to Stop" {
    var state: StoppingInput = .{};
    var running = try io.concurrent(StoppingInput.run, .{ io, &state });
    defer running.cancel(io) catch {};
    try state.stopping.wait(io);
    try std.testing.expectError(error.Canceled, running.cancel(io));
}

// --- branch ---------------------------------------------------------------

const Left = struct { seen: *Numbers };
const Right = struct { seen: *Numbers };
fn toLeft(sink: Left, value: u32) void {
    sink.seen.add(value);
}
fn toRight(sink: Right, value: u32) void {
    sink.seen.add(value);
}

test "branch hands every item to tuple and constructed sub-pipes" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        .{ map(double), forEach(toLeft) },
        pipe(.{ filter(isEven), forEach(toRight) }),
    })});
    try program(range(u32, 0, 5), work).run(.{ Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 2, 4, 6, 8 });
    try right.expect(&.{ 0, 2, 4 });
}

const Pulls = struct { count: usize = 0 };
fn countPull(pulls: *Pulls, _: u32) void {
    pulls.count += 1;
}

test "a branch stops the source once every sub-pipe is done" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var pulls: Pulls = .{};
    const work = pipe(.{ tap(countPull), branch(.{
        pipe(.{ take(2), forEach(toLeft) }),
        pipe(.{ take(4), forEach(toRight) }),
    }) });
    try program(range(u32, 0, 1000), work).run(.{ &pulls, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 1 });
    try right.expect(&.{ 0, 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 4), pulls.count);
}

test "branches finish in order when the stream ends" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ fold(@as(u32, 0), add), forEach(toLeft) }),
        pipe(.{ map(double), fold(@as(u32, 0), add), forEach(toRight) }),
    })});
    try program(range(u32, 1, 5), work).run(.{ Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{10});
    try right.expect(&.{20});
}

test "a branch that starts with a queue runs beside its siblings" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        .{ queue(4), map(slowly), forEach(toLeft) },
        pipe(.{ queue(4), map(double), forEach(toRight) }),
    })});
    try program(range(u32, 0, 30), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectEqual(@as(usize, 30), left.len);
    try std.testing.expectEqual(@as(usize, 30), right.len);
    for (left.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    for (right.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i * 2)), value);
}

test "an error in a queued branch fails the run" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), map(failAtFive), forEach(toLeft) }),
        pipe(.{ queue(2), forEach(toRight) }),
    })});
    const result = program(range(u32, 0, 20), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Five, result);
    try left.expect(&.{ 0, 1, 2, 3, 4 });
}

test "branches nest" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{forEach(record)}),
        pipe(.{ map(double), branch(.{ pipe(.{forEach(toLeft)}), pipe(.{ filter(isEven), take(1), forEach(toRight) }) }) }),
    })});
    try program(range(u32, 1, 4), work).run(.{ &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try seen.expect(&.{ 1, 2, 3 });
    try left.expect(&.{ 2, 4, 6 });
    try right.expect(&.{2});
}

// --- route ----------------------------------------------------------------

fn isSmall(value: u32) bool {
    return value < 3;
}

test "route sends each item to the first case that takes it" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{route(.{
        when(isSmall, .{forEach(toLeft)}),
        when(isEven, pipe(.{forEach(toRight)})),
        otherwise(.{forEach(record)}),
    })});
    try program(range(u32, 0, 8), work).run(.{ &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 1, 2 });
    try right.expect(&.{ 4, 6 });
    try seen.expect(&.{ 3, 5, 7 });
}

test "an item no case takes is dropped" {
    var left: Numbers = .{};
    const work = pipe(.{route(.{when(isSmall, pipe(.{forEach(toLeft)}))})});
    try program(range(u32, 0, 8), work).run(.{Left{ .seen = &left }});
    try left.expect(&.{ 0, 1, 2 });
}

fn plusHundred(value: u32) u32 {
    return value + 100;
}

test "cases that emit the same type rejoin the pipe" {
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, .{map(double)}),
            otherwise(.{map(plusHundred)}),
        }),
        forEach(record),
    });
    try program(range(u32, 0, 5), work).run(.{&seen});
    try seen.expect(&.{ 0, 101, 4, 103, 8 });
}

test "a rejoining route stops when the pipe after it is done" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    const work = pipe(.{
        tap(countPull),
        route(.{ when(isEven, pipe(.{map(double)})), otherwise(pipe(.{map(plusHundred)})) }),
        take(2),
        forEach(record),
    });
    try program(range(u32, 0, 1000), work).run(.{ &seen, &pulls });
    try seen.expect(&.{ 0, 101 });
    try std.testing.expectEqual(@as(usize, 2), pulls.count);
}

test "a case keeps its own state and finishes with the stream" {
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, .{fold(@as(u32, 0), add)}),
            otherwise(pipe(.{take(1)})),
        }),
        forEach(record),
    });
    try program(range(u32, 0, 7), work).run(.{&seen});
    try seen.expect(&.{ 1, 12 });
}

test "once the pipe after a route is done, no case forwards to it again" {
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    // Both cases emit one final value when the stream ends; only the first
    // may reach what follows the route.
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{fold(@as(u32, 0), add)})),
            otherwise(pipe(.{fold(@as(u32, 100), add)})),
        }),
        tap(countPull),
        take(1),
        forEach(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped });
    try seen.expect(&.{6});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
}

/// Forwards every item and emits one more at the end of the stream.
const Trailer = struct {
    value: u32,

    pub const zrx_operator = {};
    pub const name = "trailer";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            value: u32,

            pub fn init(self: *@This(), op: *const Trailer, _: Env) void {
                self.value = op.value;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                _ = try down.push(self.value);
            }
        };
    }
};

const Asked = struct { count: usize = 0 };
fn countedEven(asked: *Asked, value: u32) bool {
    asked.count += 1;
    return value % 2 == 0;
}

test "a route that is done asks no predicate" {
    var seen: Numbers = .{};
    var asked: Asked = .{};
    // take(1) is done after the first item. The stage before the route still
    // emits at the end of the stream: the route answers for itself, without
    // running a predicate that could fail or block over that item.
    const work = pipe(.{
        Trailer{ .value = 9 },
        route(.{
            when(countedEven, pipe(.{map(double)})),
            otherwise(pipe(.{map(double)})),
        }),
        take(1),
        forEach(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &asked });
    try seen.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 1), asked.count);
}

const Threshold = struct { value: u32 };
fn above(threshold: Threshold, value: u32) bool {
    return value > threshold.value;
}

test "case predicates use program dependencies" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{route(.{
        when(above, pipe(.{forEach(toLeft)})),
        otherwise(pipe(.{forEach(toRight)})),
    })});
    try program(range(u32, 0, 8), work).run(.{ Threshold{ .value = 2 }, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 3, 4, 5, 6, 7 });
    try right.expect(&.{ 0, 1, 2 });
}

test "terminal cases can be queued" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{route(.{
        when(isEven, pipe(.{ queue(2), forEach(toLeft) })),
        otherwise(pipe(.{ queue(2), map(double), forEach(toRight) })),
    })});
    try program(range(u32, 0, 6), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 2, 4 });
    try right.expect(&.{ 2, 6, 10 });
}

// --- segments ---------------------------------------------------------------
//
// A queue splits a pipe into segments, each a task of its own. Nothing here
// measures time: a party that should be interrupted waits far longer than a
// test should take and records whether it woke by itself.

/// A clock shared by everything in one test, so that events seen by different
/// tasks can be put in order.
const Ticks = struct {
    next: std.atomic.Value(usize) = .init(0),
};

/// What one `mark` saw, and when. Each mark has a trace of its own: marks in
/// different segments run at the same time.
fn Trace(comptime id: u8) type {
    return struct {
        events: support.Recorder(u8) = .{},
        at: support.Recorder(usize) = .{},

        /// Never read: it makes `Trace(0)` and `Trace(1)` different types,
        /// so that each mark finds its own trace among the dependencies.
        const tag = id;

        fn add(self: *@This(), ticks: *Ticks, event: u8) void {
            self.events.add(event);
            self.at.add(ticks.next.fetchAdd(1, .seq_cst));
        }

        fn count(self: *const @This(), event: u8) usize {
            return std.mem.count(u8, self.events.slice(), &.{event});
        }

        /// The moment of the only `event`.
        fn when(self: *const @This(), event: u8) !usize {
            try std.testing.expectEqual(@as(usize, 1), self.count(event));
            return self.at.slice()[std.mem.indexOfScalar(u8, self.events.slice(), event).?];
        }
    };
}

/// Passes every item on and records each hook in `*Trace(id)`:
/// construction, `p`ush and `f`inish.
fn mark(comptime id: u8) Mark(id) {
    return .{};
}

fn Mark(comptime id: u8) type {
    return struct {
        pub const zrx_operator = {};
        pub const name = "mark";

        pub fn Out(comptime _: type, comptime In: type) type {
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                trace: *Trace(id),
                ticks: *Ticks,

                pub fn init(self: *@This(), _: *const Mark(id), env: Env) void {
                    self.* = .{ .trace = zrx.di.get(env, *Trace(id)), .ticks = zrx.di.get(env, *Ticks) };
                    self.trace.add(self.ticks, 'i');
                }

                pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                    self.trace.add(self.ticks, 'p');
                    return down.push(item);
                }

                pub fn finish(self: *@This(), _: anytype) !void {
                    self.trace.add(self.ticks, 'f');
                }
            };
        }
    };
}

test "the end of the stream travels with the data: each segment finishes once" {
    var seen: Numbers = .{};
    var ticks: Ticks = .{};
    var first: Trace(0) = .{};
    var second: Trace(1) = .{};
    var third: Trace(2) = .{};
    // A slow middle segment behind a queue of one: the source has returned
    // long before the last item is handled.
    const work = pipe(.{
        mark(0),
        queue(1),
        map(slowly),
        mark(1),
        queue(1),
        fold(@as(u32, 0), add),
        mark(2),
        forEach(record),
    });
    try program(range(u32, 1, 11), work).run(.{ io, &seen, &ticks, &first, &second, &third });
    try seen.expect(&.{55});
    try first.events.expect("ippppppppppf");
    try second.events.expect("ippppppppppf");
    try third.events.expect("ipf");
    // Segments finish in stream order.
    try std.testing.expect(try first.when('f') < try second.when('f'));
    try std.testing.expect(try second.when('f') < try third.when('f'));
}

test "queued sub-pipes of a branch each finish once when the stream ends" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var trunk: Trace(0) = .{};
    var summed: Trace(1) = .{};
    var echoed: Trace(2) = .{};
    const sum = pipe(.{
        queue(2),
        mark(1),
        fold(@as(u32, 0), add),
        forEach(toLeft),
    });
    const echo = pipe(.{
        queue(2),
        map(slowly),
        mark(2),
        forEach(toRight),
    });
    const work = pipe(.{
        mark(0),
        branch(.{ sum, echo }),
    });
    try program(range(u32, 1, 6), work).run(.{ io, &ticks, &trunk, &summed, &echoed, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{15});
    try right.expect(&.{ 1, 2, 3, 4, 5 });
    try trunk.events.expect("ipppppf");
    try summed.events.expect("ipppppf");
    try echoed.events.expect("ipppppf");
}

fn failAnyhow(value: u32) anyerror!u32 {
    if (value == 5) return error.Five;
    return value;
}

test "a queue works in a pipe whose handlers return anyerror" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 10), pipe(.{ queue(2), map(failAnyhow), forEach(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

test "concurrent supports handlers returning anyerror" {
    const result = program(range(u32, 0, 10), .{ concurrent(3, .{map(failAnyhow)}), drain() }).run(.{io});
    try std.testing.expectError(error.Five, result);
}

test "Io may be provided where the queue needs it" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 5), pipe(.{ queue(2), forEach(record) })).provide(.{io}).run(.{&seen});
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

const Stalled = struct {
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

/// A source that pushes `value` and then waits for input that never comes.
fn PushThenStall(comptime value: u32) type {
    return struct {
        fn run(clock: std.Io, stalled: *Stalled, out: anytype) !void {
            _ = try out.push(value);
            try clock.sleep(.fromSeconds(5), .awake);
            stalled.woke_by_itself.store(true, .seq_cst);
        }
    };
}

test "a failure after a queue ends the run while the source is waiting" {
    var seen: Numbers = .{};
    var stalled: Stalled = .{};
    const source = fromProducer(u32, PushThenStall(5).run);
    const result = program(source, pipe(.{ queue(2), map(failAtFive), forEach(record) })).run(.{ io, &seen, &stalled });
    try std.testing.expectError(error.Five, result);
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

test "a concurrent worker failure interrupts an idle source" {
    var stalled: Stalled = .{};
    var seen: Numbers = .{};
    const source = fromProducer(u32, PushThenStall(5).run);
    try std.testing.expectError(error.Five, program(source, .{ concurrent(3, .{map(failAtFive)}), forEach(record) }).run(.{ io, &seen, &stalled }));
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

test "concurrent retirement wakes waits that do not observe cancellation" {
    const clock = support.UncancelableWaits.over(io);
    try std.testing.expectError(error.Ended, program(range(u32, 0, 1000), .{ concurrent(2, .{map(failAlways)}), drain() }).run(.{clock}));
}

test "a failure behind two queues, or in a queued sub-pipe, ends the run while the source is waiting" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var stalled: Stalled = .{};
    const source = fromProducer(u32, PushThenStall(5).run);
    const deps = .{ io, &stalled, Left{ .seen = &left }, Right{ .seen = &right } };

    const twice = pipe(.{ queue(2), map(double), queue(2), map(failAtTen), forEach(toLeft) });
    try std.testing.expectError(error.Ten, program(source, twice).run(deps));

    const failing = pipe(.{
        queue(2),
        map(failAtFive),
        forEach(toLeft),
    });
    const split = pipe(.{branch(.{ failing, pipe(.{forEach(toRight)}) })});
    try std.testing.expectError(error.Five, program(source, split).run(deps));

    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

fn failAtTen(value: u32) error{Ten}!u32 {
    if (value == 10) return error.Ten;
    return value;
}

/// What the teardown test watches.
const Hold = struct {
    holding: std.atomic.Value(bool) = .init(false),
    outer_released: std.atomic.Value(bool) = .init(false),
    inner_released: std.atomic.Value(bool) = .init(false),
    released_while_held: std.atomic.Value(bool) = .init(false),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};
const Outer = struct { hold: *Hold };
const Inner = struct { hold: *Hold };

fn acquireOuter(hold: *Hold) Outer {
    return .{ .hold = hold };
}
fn releaseOuter(outer: Outer) void {
    outer.hold.outer_released.store(true, .seq_cst);
}
fn acquireInner(hold: *Hold) Inner {
    return .{ .hold = hold };
}
fn releaseInner(inner: Inner) void {
    inner.hold.inner_released.store(true, .seq_cst);
}

/// Holds both resources until it is interrupted, then looks whether either
/// was released under it.
fn holdBoth(clock: std.Io, outer: Outer, inner: Inner, _: u32) !void {
    const hold = outer.hold;
    hold.holding.store(true, .seq_cst);
    clock.sleep(.fromSeconds(5), .awake) catch |err| {
        if (hold.outer_released.load(.seq_cst) or inner.hold.inner_released.load(.seq_cst))
            hold.released_while_held.store(true, .seq_cst);
        return err;
    };
    hold.woke_by_itself.store(true, .seq_cst);
}

/// Fails once the handler behind the queue is at work.
fn pushThenFail(hold: *Hold, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    while (!hold.holding.load(.seq_cst)) std.Thread.yield() catch {};
    return error.SourceFailed;
}

test "nothing is released while a handler behind a queue is still using it" {
    var hold: Hold = .{};
    const work = pipe(.{
        queue(2),
        forEach(holdBoth),
    });
    const result = program(fromProducer(u32, pushThenFail), work).provide(.{ resource(acquireOuter, releaseOuter), resource(acquireInner, releaseInner) }).run(.{ io, &hold });
    try std.testing.expectError(error.SourceFailed, result);
    try std.testing.expect(!hold.woke_by_itself.load(.seq_cst));
    try std.testing.expect(!hold.released_while_held.load(.seq_cst));
    try std.testing.expect(hold.outer_released.load(.seq_cst) and hold.inner_released.load(.seq_cst));
}

test "resources outlive every concurrent worker on failure" {
    var hold: Hold = .{};
    const app = program(fromProducer(u32, pushThenFail), .{concurrent(3, .{forEach(holdBoth)})})
        .provide(.{ resource(acquireOuter, releaseOuter), resource(acquireInner, releaseInner) });
    try std.testing.expectError(error.SourceFailed, app.run(.{ io, &hold }));
    try std.testing.expect(!hold.woke_by_itself.load(.seq_cst));
    try std.testing.expect(!hold.released_while_held.load(.seq_cst));
    try std.testing.expect(hold.outer_released.load(.seq_cst) and hold.inner_released.load(.seq_cst));
}

/// What the failure-while-draining test watches.
const Ending = struct {
    draining: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
};

/// Sets `Ending.ended` when the stream ends where it stands.
const RaiseAtEnd = struct {
    pub const zrx_operator = {};
    pub const name = "raiseAtEnd";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            ending: *Ending,

            pub fn init(self: *@This(), _: *const RaiseAtEnd, env: Env) void {
                self.ending = zrx.di.get(env, *Ending);
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), _: anytype) !void {
                self.ending.ended.store(true, .seq_cst);
            }
        };
    }
};

/// Holds the first item until the run interrupts this task, then carries on
/// as if nothing had happened. It waits without sleeping, so that only the
/// run's own check can keep the stream from ending normally here.
fn carryOnWhenInterrupted(clock: std.Io, ending: *Ending, value: u32) u32 {
    ending.draining.store(true, .seq_cst);
    while (!ending.interrupted.load(.seq_cst)) {
        clock.checkCancel() catch ending.interrupted.store(true, .seq_cst);
        std.Thread.yield() catch {};
    }
    return value;
}

/// Fails once its sibling is draining and the stream has ended for both.
fn failOnceDraining(ending: *Ending, _: u32) error{Late}!u32 {
    while (!ending.draining.load(.seq_cst) or !ending.ended.load(.seq_cst)) std.Thread.yield() catch {};
    return error.Late;
}

test "once a segment has failed, no other segment ends its stream normally" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var trunk: Trace(0) = .{};
    var summed: Trace(1) = .{};
    var ending: Ending = .{};
    // The source has ended and this sub-pipe has every item: left alone, it
    // would fold them and emit the sum.
    const draining = pipe(.{
        queue(8),
        map(carryOnWhenInterrupted),
        fold(@as(u32, 0), add),
        mark(1),
        forEach(toLeft),
    });
    const failing = pipe(.{
        RaiseAtEnd{},
        queue(8),
        map(failOnceDraining),
        forEach(toRight),
    });
    const work = pipe(.{
        mark(0),
        branch(.{ draining, failing }),
    });
    const result = program(range(u32, 1, 4), work).run(.{ io, &ticks, &trunk, &summed, &ending, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Late, result);
    try left.expect(&.{});
    // The first segment had ended before the failure.
    try trunk.events.expect("ipppf");
    try summed.events.expect("i");
}

/// A source that pushes one item, waits until the run interrupts it, and
/// then returns as if it had simply run out. It waits without sleeping, so
/// that only the run's own check can keep the stream from ending normally.
fn pushThenEndWhenInterrupted(clock: std.Io, out: anytype) !void {
    _ = try out.push(@as(u32, 5));
    while (true) {
        clock.checkCancel() catch return;
        std.Thread.yield() catch {};
    }
}

test "a source that returns after a failure elsewhere does not end the stream" {
    var seen: Numbers = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    const work = pipe(.{
        mark(0),
        queue(2),
        map(failAtFive),
        forEach(record),
    });
    const result = program(fromProducer(u32, pushThenEndWhenInterrupted), work).run(.{ io, &seen, &ticks, &before });
    try std.testing.expectError(error.Five, result);
    try before.events.expect("ip");
}

/// Set when a program run by `Called` has returned.
var called_returned: std.atomic.Value(bool) = .init(false);

/// Runs a program on a task of its own, so that a test can cancel its caller.
fn Called(comptime Program: type, comptime Deps: type) type {
    return struct {
        fn run(called: *const Program, deps: Deps) ?anyerror {
            defer called_returned.store(true, .seq_cst);
            called.run(deps) catch |err| return err;
            return null;
        }
    };
}

/// Waits until the run is held where `support.JoinHeld` holds it. A run that
/// returns without ever being held ends the wait too, so that a missing look
/// at the caller's cancellation shows as a wrong result and not as a hang.
fn untilHeldAtJoin() void {
    while (!support.JoinHeld.joining.load(.seq_cst) and !called_returned.load(.seq_cst)) std.Thread.yield() catch {};
}

const Caught = struct {
    handled: std.atomic.Value(bool) = .init(false),
};
fn noteHandled(caught: *Caught, _: u32) void {
    caught.handled.store(true, .seq_cst);
}

test "cancelling the caller of a queued program cancels every segment and skips the end of the stream" {
    var stalled: Stalled = .{};
    var caught: Caught = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    var after: Trace(1) = .{};
    const work = pipe(.{
        mark(0),
        queue(2),
        mark(1),
        forEach(noteHandled),
    });
    const waiting = program(fromProducer(u32, PushThenStall(1).run), work);
    const Deps = struct { std.Io, *Stalled, *Caught, *Ticks, *Trace(0), *Trace(1) };
    var caller = try io.concurrent(Called(@TypeOf(waiting), Deps).run, .{ &waiting, Deps{ io, &stalled, &caught, &ticks, &before, &after } });
    // An item got through, so both segments are running and the caller waits.
    while (!caught.handled.load(.seq_cst)) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
    try before.events.expect("ip");
    try after.events.expect("ip");
}

// --- invariants over shapes ---------------------------------------------------
//
// Not cases but rules, checked for every shape below and every way its
// "ended" side can end: the items run out, that side is done after one item,
// or it fails on the first. The source never waits for input and pushes far
// more than the queues hold, so a producer left waiting on a queue hangs the
// run.
//
// 1. The run returns.
// 2. A sub-pipe beside the ended side gets every item meant for it.
// 3. On success every stage finishes once.
// 4. On the failing input in this test nothing finishes: the failure
//    comes with the first item, long before the source could have run out,
//    and it is on record before anybody is let go by it.

const Way = enum { runs_out, done, fails };

fn same(value: u32) u32 {
    return value;
}
fn failAlways(_: u32) error{Ended}!u32 {
    return error.Ended;
}

fn Ender(comptime ending: Way) type {
    return switch (ending) {
        .runs_out => @TypeOf(map(same)),
        .done => @TypeOf(take(1)),
        .fails => @TypeOf(map(failAlways)),
    };
}

fn ender(comptime ending: Way) Ender(ending) {
    return switch (ending) {
        .runs_out => map(same),
        .done => take(1),
        .fails => map(failAlways),
    };
}

const item_count = 24;

/// Everything one run of a shape is watched with.
const Probe = struct {
    ticks: Ticks = .{},
    t0: Trace(0) = .{},
    t1: Trace(1) = .{},
    t2: Trace(2) = .{},
    t3: Trace(3) = .{},
    t4: Trace(4) = .{},
    ended: Numbers = .{},
    beside: Numbers = .{},

    fn run(probe: *Probe, comptime shape: anytype, comptime ending: Way) !void {
        const deps = .{ io, &probe.ticks, &probe.t0, &probe.t1, &probe.t2, &probe.t3, &probe.t4, Left{ .seen = &probe.ended }, Right{ .seen = &probe.beside } };
        const result = program(range(u32, 0, item_count), shape.build(ending)).run(deps);
        if (ending == .fails) {
            try std.testing.expectError(error.Ended, result);
        } else {
            try result;
            try std.testing.expectEqual(shape.beside(), probe.beside.len);
            const wanted = if (ending == .done) (if (@hasDecl(shape, "doneCount")) shape.doneCount() else 1) else shape.ended();
            try std.testing.expectEqual(wanted, probe.ended.len);
        }
        inline for (.{ &probe.t0, &probe.t1, &probe.t2, &probe.t3, &probe.t4 }) |trace| {
            if (trace.events.len > 0) {
                if (ending == .fails) {
                    try std.testing.expectEqual(@as(usize, 0), trace.count('f'));
                } else {
                    try std.testing.expectEqual(@as(usize, 1), trace.count('f'));
                }
            }
        }
    }
};

fn checkShape(comptime shape: type) !void {
    inline for (.{ Way.runs_out, Way.done, Way.fails }) |ending| {
        for (0..20) |_| {
            var probe: Probe = .{};
            try probe.run(shape, ending);
        }
    }
}

/// Three segments in a row.
const InARow = struct {
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) })) {
        return pipe(.{ mark(0), queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return 0;
    }
};

/// The ended side is two segments deep; the source also feeds a sub-pipe directly.
const BesideTheSource = struct {
    fn Deep(comptime ending: Way) type {
        return @TypeOf(pipe(.{ queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) }));
    }
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), branch(.{ @as(Deep(ending), undefined), pipe(.{forEach(toRight)}) }) })) {
        const deep: Deep(ending) = pipe(.{ queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) });
        return pipe(.{ mark(0), branch(.{ deep, pipe(.{forEach(toRight)}) }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

/// A segment behind a queue feeds the ended side through another queue and a sub-pipe directly.
const BesideASegment = struct {
    fn Last(comptime ending: Way) type {
        return @TypeOf(pipe(.{ queue(1), mark(2), ender(ending), forEach(toLeft) }));
    }
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), queue(1), mark(1), branch(.{ @as(Last(ending), undefined), pipe(.{forEach(toRight)}) }) })) {
        const last: Last(ending) = pipe(.{ queue(1), mark(2), ender(ending), forEach(toLeft) });
        return pipe(.{ mark(0), queue(1), mark(1), branch(.{ last, pipe(.{forEach(toRight)}) }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

/// Two queued sub-pipes of one branch: one ends, the other takes everything.
const TwoQueued = struct {
    fn First(comptime ending: Way) type {
        return @TypeOf(pipe(.{ queue(1), mark(1), ender(ending), forEach(toLeft) }));
    }
    const Second = @TypeOf(pipe(.{ queue(1), mark(2), forEach(toRight) }));
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), branch(.{ @as(First(ending), undefined), @as(Second, undefined) }) })) {
        const first: First(ending) = pipe(.{ queue(1), mark(1), ender(ending), forEach(toLeft) });
        const second: Second = pipe(.{ queue(1), mark(2), forEach(toRight) });
        return pipe(.{ mark(0), branch(.{ first, second }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

/// Behind a queue, a branch of a sub-pipe two segments deep and a queued one.
const Nested = struct {
    fn Deep(comptime ending: Way) type {
        return @TypeOf(pipe(.{ queue(1), mark(2), queue(1), mark(3), ender(ending), forEach(toLeft) }));
    }
    const Other = @TypeOf(pipe(.{ queue(1), mark(4), forEach(toRight) }));
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), queue(1), mark(1), branch(.{ @as(Deep(ending), undefined), @as(Other, undefined) }) })) {
        const deep: Deep(ending) = pipe(.{ queue(1), mark(2), queue(1), mark(3), ender(ending), forEach(toLeft) });
        const other: Other = pipe(.{ queue(1), mark(4), forEach(toRight) });
        return pipe(.{ mark(0), queue(1), mark(1), branch(.{ deep, other }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

/// A route whose cases are both queued: the even items go to the ended side.
const Routed = struct {
    fn Even(comptime ending: Way) type {
        return @TypeOf(pipe(.{ queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) }));
    }
    const Odd = @TypeOf(pipe(.{ queue(1), mark(3), forEach(toRight) }));
    fn Cases(comptime ending: Way) type {
        return @TypeOf(route(.{ when(isEven, @as(Even(ending), undefined)), otherwise(@as(Odd, undefined)) }));
    }
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), @as(Cases(ending), undefined) })) {
        const even: Even(ending) = pipe(.{ queue(1), mark(1), queue(1), mark(2), ender(ending), forEach(toLeft) });
        const odd: Odd = pipe(.{ queue(1), mark(3), forEach(toRight) });
        return pipe(.{ mark(0), route(.{ when(isEven, even), otherwise(odd) }) });
    }
    fn ended() usize {
        return item_count / 2;
    }
    fn beside() usize {
        return item_count / 2;
    }
};

test "invariants: three segments in a row" {
    try checkShape(InARow);
}
test "invariants: the ended side beside a direct sub-pipe of the source" {
    try checkShape(BesideTheSource);
}
test "invariants: the ended side beside a direct sub-pipe of a segment" {
    try checkShape(BesideASegment);
}
test "invariants: two queued sub-pipes" {
    try checkShape(TwoQueued);
}
test "invariants: a branch behind a queue" {
    try checkShape(Nested);
}
test "invariants: queued cases of a route" {
    try checkShape(Routed);
}

const ConcurrentInARow = struct {
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), concurrent(3, .{map(same)}), mark(1), concurrent(2, .{map(same)}), mark(2), ender(ending), forEach(toLeft) })) {
        return pipe(.{ mark(0), concurrent(3, .{map(same)}), mark(1), concurrent(2, .{map(same)}), mark(2), ender(ending), forEach(toLeft) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return 0;
    }
};

const ConcurrentWorkers = struct {
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), concurrent(3, .{ender(ending)}), mark(1), forEach(toLeft) })) {
        return pipe(.{ mark(0), concurrent(3, .{ender(ending)}), mark(1), forEach(toLeft) });
    }
    fn ended() usize {
        return item_count;
    }
    pub fn doneCount() usize {
        return 3;
    }
    fn beside() usize {
        return 0;
    }
};

const ConcurrentBeside = struct {
    fn First(comptime ending: Way) type {
        return @TypeOf(pipe(.{ concurrent(3, .{map(same)}), mark(1), ender(ending), forEach(toLeft) }));
    }
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), branch(.{ @as(First(ending), undefined), .{ queue(1), mark(2), forEach(toRight) } }) })) {
        const first: First(ending) = pipe(.{ concurrent(3, .{map(same)}), mark(1), ender(ending), forEach(toLeft) });
        return pipe(.{ mark(0), branch(.{ first, .{ queue(1), mark(2), forEach(toRight) } }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

const ConcurrentRouted = struct {
    fn Even(comptime ending: Way) type {
        return @TypeOf(pipe(.{ concurrent(3, .{map(same)}), mark(1), ender(ending), forEach(toLeft) }));
    }
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), route(.{ when(isEven, @as(Even(ending), undefined)), otherwise(.{ queue(1), mark(2), forEach(toRight) }) }) })) {
        const even: Even(ending) = pipe(.{ concurrent(3, .{map(same)}), mark(1), ender(ending), forEach(toLeft) });
        return pipe(.{ mark(0), route(.{ when(isEven, even), otherwise(.{ queue(1), mark(2), forEach(toRight) }) }) });
    }
    fn ended() usize {
        return item_count / 2;
    }
    fn beside() usize {
        return item_count / 2;
    }
};

test "invariants: consecutive concurrent boundaries" {
    try checkShape(ConcurrentInARow);
}
test "invariants: concurrent worker pipes run out, stop, or fail" {
    try checkShape(ConcurrentWorkers);
}
test "invariants: concurrent workers beside a queued branch" {
    try checkShape(ConcurrentBeside);
}
test "invariants: concurrent workers in a terminal route case" {
    try checkShape(ConcurrentRouted);
}

/// Timed batching between queues, with a direct sibling after it.
const TimedBatches = struct {
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), queue(1), zrx.batchWithin(3, .fromSeconds(3600)), zrx.flatten(), mark(1), branch(.{
        pipe(.{ queue(1), mark(2), ender(ending), forEach(toLeft) }),
        pipe(.{forEach(toRight)}),
    }) })) {
        return pipe(.{ mark(0), queue(1), zrx.batchWithin(3, .fromSeconds(3600)), zrx.flatten(), mark(1), branch(.{
            pipe(.{ queue(1), mark(2), ender(ending), forEach(toLeft) }),
            pipe(.{forEach(toRight)}),
        }) });
    }
    fn ended() usize {
        return item_count;
    }
    fn beside() usize {
        return item_count;
    }
};

/// A debounced branch beside a queued one. Input end releases its last item.
const Debounced = struct {
    fn build(comptime ending: Way) @TypeOf(pipe(.{ mark(0), branch(.{
        pipe(.{ mark(1), ender(ending), zrx.debounce(.fromSeconds(3600)), mark(3), forEach(toLeft) }),
        pipe(.{ queue(1), mark(2), forEach(toRight) }),
    }) })) {
        return pipe(.{ mark(0), branch(.{
            pipe(.{ mark(1), ender(ending), zrx.debounce(.fromSeconds(3600)), mark(3), forEach(toLeft) }),
            pipe(.{ queue(1), mark(2), forEach(toRight) }),
        }) });
    }
    fn ended() usize {
        return 1;
    }
    fn beside() usize {
        return item_count;
    }
};

test "invariants: timed batching between queues" {
    try checkShape(TimedBatches);
}

test "invariants: a debounced sub-pipe beside a queue" {
    try checkShape(Debounced);
}

// --- decisions ------------------------------------------------------------------
//
// A decision is taken right before what it allows, after every step that can
// take time. Each test here makes one such step take its time.

/// Fails once the boundary beside it has begun to retire.
fn failOnceRetiring(gate: *support.RetireGate, _: u32) error{Late}!u32 {
    while (!gate.retiring.load(.seq_cst)) std.Thread.yield() catch {};
    return error.Late;
}

test "a segment decides to end its stream after it has retired, not before" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var beyond: Trace(1) = .{};
    var gate: support.RetireGate = .{};
    // The first sub-pipe has every item and its input has ended. It takes
    // its time retiring; meanwhile the other one fails.
    const retiring = pipe(.{
        support.handoff(8),
        mark(1),
        forEach(toLeft),
    });
    const failing = pipe(.{
        queue(8),
        map(failOnceRetiring),
        forEach(toRight),
    });
    const work = pipe(.{branch(.{ retiring, failing })});
    const result = program(range(u32, 1, 4), work).run(.{ io, &ticks, &beyond, &gate, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Late, result);
    try left.expect(&.{ 1, 2, 3 });
    try beyond.events.expect("ippp");
}

test "a cancel request that reaches the caller while the run joins its tasks is not lost" {
    var seen: Numbers = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    var after: Trace(1) = .{};
    const work = pipe(.{
        mark(0),
        queue(2),
        mark(1),
        forEach(record),
    });
    const finite = program(range(u32, 0, 3), work);
    const Deps = struct { std.Io, *Numbers, *Ticks, *Trace(0), *Trace(1) };
    // The run is held at its first join until its caller has been asked to
    // cancel: by then every segment has ended its stream by itself.
    called_returned.store(false, .seq_cst);
    const held = support.JoinHeld.over(io);
    var caller = try io.concurrent(Called(@TypeOf(finite), Deps).run, .{ &finite, Deps{ held, &seen, &ticks, &before, &after } });
    untilHeldAtJoin();
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
    try seen.expect(&.{ 0, 1, 2 });
    // Both segments had finished before cancellation.
    try before.events.expect("ipppf");
    try after.events.expect("ipppf");
}

test "the caller's cancellation also comes before a failure the run already has" {
    var seen: Numbers = .{};
    const failing = program(range(u32, 5, 8), pipe(.{ queue(2), map(failAtFive), forEach(record) }));
    const Deps = struct { std.Io, *Numbers };
    called_returned.store(false, .seq_cst);
    const held = support.JoinHeld.over(io);
    var caller = try io.concurrent(Called(@TypeOf(failing), Deps).run, .{ &failing, Deps{ held, &seen } });
    untilHeldAtJoin();
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
}

/// Lets a retiring `handoff` go once the stream has ended where this stands.
const ReleaseGateAtEnd = struct {
    pub const zrx_operator = {};
    pub const name = "releaseGateAtEnd";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            gate: *support.RetireGate,

            pub fn init(self: *@This(), _: *const ReleaseGateAtEnd, env: Env) void {
                self.gate = zrx.di.get(env, *support.RetireGate);
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), _: anytype) !void {
                self.gate.released.store(true, .seq_cst);
            }
        };
    }
};

fn pushUntilDone(out: anytype) !void {
    var value: u32 = 0;
    while (try out.push(value) != .done) value += 1;
}

test "a failure is on record before the queue behind it lets its producer go" {
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    // The far side fails on the first item. Its boundary lets the producer
    // go as soon as it retires and then waits: for the run to interrupt it,
    // or for the producer's segment to end its stream, which is what a
    // producer does that was let go without a failure on record.
    var gate: support.RetireGate = .{ .close_first = true };
    const work = pipe(.{
        mark(0),
        ReleaseGateAtEnd{},
        support.handoff(8),
        map(failAlways),
        forEach(toRight),
    });
    const result = program(fromProducer(u32, pushUntilDone), work).run(.{ io, &ticks, &before, &gate, Right{ .seen = &right } });
    try std.testing.expectError(error.Ended, result);
    try std.testing.expectEqual(@as(usize, 0), before.count('f'));
}

test "a failure while a segment ends its stream fails the run" {
    var seen: Numbers = .{};
    // Behind a queue, and in the source's own segment: the fold's final value
    // fails in the stage after it.
    const behind = pipe(.{ queue(2), fold(@as(u32, 0), add), map(failAlways), forEach(record) });
    try std.testing.expectError(error.Ended, program(range(u32, 1, 4), behind).run(.{ io, &seen }));
    const before = pipe(.{ fold(@as(u32, 0), add), map(failAlways), queue(2), forEach(record) });
    try std.testing.expectError(error.Ended, program(range(u32, 1, 4), before).run(.{ io, &seen }));
    try seen.expect(&.{});
}

const Acked = struct {
    /// The handler behind the first queue is waiting in its `Io` call.
    waiting: std.atomic.Value(bool) = .init(false),
    /// That handler has returned, one way or the other.
    returned: std.atomic.Value(bool) = .init(false),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

/// Pushes one item and then waits, without calling into `std.Io`, until the
/// handler that took it has returned. It never notices a request to cancel.
fn pushThenAwaitAck(acked: *Acked, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    while (!acked.returned.load(.seq_cst)) std.Thread.yield() catch {};
}

/// Waits in an `Io` call far longer than the test.
fn waitInIo(clock: std.Io, acked: *Acked, _: u32) !void {
    defer acked.returned.store(true, .seq_cst);
    acked.waiting.store(true, .seq_cst);
    try clock.sleep(.fromSeconds(5), .awake);
    acked.woke_by_itself.store(true, .seq_cst);
}

/// Fails once the handler beside it is waiting.
fn failOnceWaiting(acked: *Acked, _: u32) error{Late}!u32 {
    while (!acked.waiting.load(.seq_cst)) std.Thread.yield() catch {};
    return error.Late;
}

fn ignore(_: u32) void {}

test "every task is asked to cancel at once: one that does not notice does not shield another" {
    var acked: Acked = .{};
    // The source does not notice a request and waits for the handler; the
    // handler waits in an `Io` call. Asked one after another, the source
    // first, the handler would never be asked.
    const waiting = pipe(.{
        queue(2),
        forEach(waitInIo),
    });
    const failing = pipe(.{
        queue(2),
        map(failOnceWaiting),
        forEach(ignore),
    });
    const work = pipe(.{branch(.{ waiting, failing })});
    const result = program(fromProducer(u32, pushThenAwaitAck), work).run(.{ io, &acked });
    try std.testing.expectError(error.Late, result);
    try std.testing.expect(!acked.woke_by_itself.load(.seq_cst));
}

test "the caller is asked to cancel while the run starts its tasks" {
    // Not `std.testing.io`: in Debug its allocator takes a stack trace
    // through a lock that can be cancelled, and so uses up a request that
    // is pending while a task is being started (6 of 300 runs here lost it;
    // none did over a plain allocator, nor in ReleaseFast).
    var backend: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer backend.deinit();
    const plain = backend.io();
    // Held at the start of the first task, and of the second: by then the
    // first is already running.
    inline for (.{ 1, 2 }) |nth| {
        var seen: Numbers = .{};
        var stalled: Stalled = .{};
        const waiting = program(fromProducer(u32, PushThenStall(1).run), pipe(.{ queue(2), forEach(record) }));
        const Deps = struct { std.Io, *Numbers, *Stalled };
        var caller = try plain.concurrent(Called(@TypeOf(waiting), Deps).run, .{ &waiting, Deps{ support.LaunchHeld.over(plain, nth), &seen, &stalled } });
        while (!support.LaunchHeld.launching.load(.seq_cst)) std.Thread.yield() catch {};
        try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(plain));
        try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
    }
}
