//! Timed operators, with input and clock advances controlled by the test.
const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const io = std.testing.io;

const Clock = zrx.testing.Clock;

const Input = struct {
    const Action = union(enum) { item: u32, end, fail };
    slots: [1]Action = undefined,
    actions: Io.Queue(Action) = undefined,
    accepted: Io.Event = .unset,

    fn init(self: *Input) void {
        self.actions = .init(&self.slots);
    }

    fn send(self: *Input, value: u32) !void {
        self.accepted.reset();
        try self.actions.putOne(io, .{ .item = value });
        try self.accepted.wait(io);
    }

    fn produce(self: *Input, out: anytype) !void {
        while (true) switch (try self.actions.getOne(io)) {
            .item => |item| {
                const flow = try out.push(item);
                self.accepted.set(io);
                if (flow == .done) return;
            },
            .end => return,
            .fail => return error.SourceFailed,
        };
    }
};

const Result = struct { len: usize, first: u32, last: u32 };

const Output = struct {
    slots: [8]Result = undefined,
    results: Io.Queue(Result) = undefined,
    hold: ?*Hold = null,

    const Hold = struct {
        entered: Io.Event = .unset,
        released: Io.Event = .unset,
    };

    fn init(self: *Output) void {
        self.results = .init(&self.slots);
    }

    fn collect(self: *Output, item: anytype) !void {
        const result: Result = if (@TypeOf(item) == u32)
            .{ .len = 1, .first = item, .last = item }
        else
            .{ .len = item.len, .first = item.slice()[0], .last = item.slice()[item.len - 1] };
        try self.results.putOne(io, result);
        if (self.hold) |hold| {
            self.hold = null;
            hold.entered.set(io);
            try hold.released.wait(io);
        }
    }

    fn expect(self: *Output, len: usize, first: u32, last: u32) !void {
        try std.testing.expectEqual(Result{ .len = len, .first = first, .last = last }, try self.results.getOne(io));
    }
};

fn Run(comptime op: anytype) type {
    return struct {
        fn run(clock: Io, input: *Input, output: *Output) !void {
            try zrx.program(zrx.fromProducer(u32, Input.produce), zrx.pipe(.{ op, zrx.forEach(Output.collect) })).run(.{ clock, input, output });
        }
    };
}

/// What a test outside this repository can write: see "Testing timed
/// operators" in the guide, which shows this test.
const Window = zrx.Batch(u32, 8);

const Windows = struct {
    slots: [2]Window = undefined,
    seen: Io.Queue(Window) = undefined,

    fn init(self: *Windows) void {
        self.seen = .init(&self.slots);
    }

    fn collect(self: *Windows, window: Window) !void {
        try self.seen.putOne(io, window);
    }
};

fn collectWindows(timed: Io, input: *Input, windows: *Windows) !void {
    try zrx.program(zrx.fromProducer(u32, Input.produce), zrx.pipe(.{
        zrx.batchWithin(8, .fromMilliseconds(200)),
        zrx.forEach(Windows.collect),
    })).run(.{ timed, input, windows });
}

test "zrx.testing.Clock lets a test assert the exact batch of a source that is still open" {
    var clock: zrx.testing.Clock = .init(io);
    var input: Input = .{};
    input.init();
    var windows: Windows = .{};
    windows.init();
    var run = try io.concurrent(collectWindows, .{ clock.io(), &input, &windows });
    defer _ = run.cancel(io) catch {};

    for ([_]u32{ 7, 8, 9 }) |reading| try input.send(reading);
    try clock.waitingAt(.fromMilliseconds(200));
    clock.advanceTo(.fromMilliseconds(200));
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, (try windows.seen.getOne(io)).slice());

    // The source is open: its next item starts a window at the new time.
    try input.send(10);
    try clock.waitingAt(.fromMilliseconds(400));
    try input.actions.putOne(io, .end);
    try run.await(io);
    try std.testing.expectEqualSlices(u32, &.{10}, (try windows.seen.getOne(io)).slice());
}

test "zrx.testing.Clock times a wait given as a duration from the time it has" {
    var clock: zrx.testing.Clock = .init(io);
    clock.advanceTo(.fromSeconds(3));
    var event: Io.Event = .unset;
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };
    var waiting = try io.concurrent(Io.Event.waitTimeout, .{ &event, clock.io(), timeout });
    defer _ = waiting.cancel(io) catch {};
    try clock.waitingAt(.fromSeconds(8));
    clock.advanceTo(.fromSeconds(8));
    try std.testing.expectError(error.Timeout, waiting.await(io));
}

test "zrx.testing.Clock returns at once from a wait that is already over" {
    var clock: zrx.testing.Clock = .init(io);
    const timed = clock.io();
    clock.advanceTo(.fromSeconds(2));
    const past: Io.Timeout = .{ .deadline = Io.Timestamp.zero.addDuration(.fromSeconds(1)).withClock(.awake) };
    const later: Io.Timeout = .{ .deadline = Io.Timestamp.zero.addDuration(.fromSeconds(3)).withClock(.awake) };
    var word: u32 = 1;
    // The deadline has passed. A wait that started now would miss the
    // advance that was meant to end it.
    try timed.futexWaitTimeout(u32, &word, 1, past);
    // The value has changed. Its wake came before this wait and is not repeated.
    try timed.futexWaitTimeout(u32, &word, 0, later);
}

test "batchWithin emits 900 of 1000 while the source is idle" {
    var clock: Clock = .init(io);
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(1000, .fromSeconds(60))).run, .{ clock.io(), &input, &output });
    defer _ = run.cancel(io) catch {};
    for (0..900) |index| try input.send(@intCast(index));
    try clock.waitingAt(.fromSeconds(60));
    clock.advanceTo(.fromSeconds(60));
    try output.expect(900, 0, 899);
    try input.actions.putOne(io, .end);
    try run.await(io);
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "batchWithin keeps the first deadline and starts a new one after emission" {
    var clock: Clock = .init(io);
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(3, .fromSeconds(60))).run, .{ clock.io(), &input, &output });
    defer _ = run.cancel(io) catch {};
    // An empty batch has no deadline. Its first item arrives at t=100.
    clock.advanceTo(.fromSeconds(100));
    try input.send(1);
    try clock.waitingAt(.fromSeconds(160));
    clock.advanceTo(.fromSeconds(130));
    try input.send(2);
    try clock.waitingAt(.fromSeconds(160));
    clock.advanceTo(.fromSeconds(160));
    try output.expect(2, 1, 2);
    try input.send(3);
    try input.send(4);
    try input.send(5);
    try output.expect(3, 3, 5);
    clock.advanceTo(.fromSeconds(180));
    try input.send(6);
    try clock.waitingAt(.fromSeconds(240));
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 6, 6);
}

test "debounce restarts its deadline and emits the latest item during source silence" {
    var clock: Clock = .init(io);
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.debounce(.fromSeconds(10))).run, .{ clock.io(), &input, &output });
    defer _ = run.cancel(io) catch {};
    try input.send(1);
    try clock.waitingAt(.fromSeconds(10));
    clock.advanceTo(.fromSeconds(5));
    try input.send(2);
    try clock.waitingAt(.fromSeconds(15));
    clock.advanceTo(.fromSeconds(10));
    try clock.waitingAt(.fromSeconds(15));
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
    clock.advanceTo(.fromSeconds(15));
    try output.expect(1, 2, 2);
    try input.send(3);
    try clock.waitingAt(.fromSeconds(25));
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 3, 3);
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "timed operators propagate source failure and caller cancellation while waiting" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        inline for (.{ false, true }) |cancel| {
            var clock: Clock = .init(io);
            var input: Input = .{};
            input.init();
            var output: Output = .{};
            output.init();
            var run = try io.concurrent(Run(op).run, .{ clock.io(), &input, &output });
            defer _ = run.cancel(io) catch {};
            try input.send(1);
            try clock.waitingAt(.fromSeconds(60));
            if (cancel) {
                try std.testing.expectError(error.Canceled, run.cancel(io));
            } else {
                try input.actions.putOne(io, .fail);
                try std.testing.expectError(error.SourceFailed, run.await(io));
            }
        }
    }
}

test "debounce coalesces input while downstream is busy" {
    var clock: Clock = .init(io);
    var input: Input = .{};
    input.init();
    var hold: Output.Hold = .{};
    var output: Output = .{ .hold = &hold };
    output.init();
    var run = try io.concurrent(Run(zrx.debounce(.fromSeconds(10))).run, .{ clock.io(), &input, &output });
    defer _ = run.cancel(io) catch {};
    try input.send(1);
    try clock.waitingAt(.fromSeconds(10));
    clock.advanceTo(.fromSeconds(10));
    try hold.entered.wait(io);
    try output.expect(1, 1, 1);
    clock.advanceTo(.fromSeconds(11));
    try input.send(2);
    clock.advanceTo(.fromSeconds(12));
    try input.send(3);
    clock.advanceTo(.fromSeconds(13));
    try input.send(4);
    clock.advanceTo(.fromSeconds(23));
    hold.released.set(io);
    try output.expect(1, 4, 4);
    try input.actions.putOne(io, .end);
    try run.await(io);
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "batchWithin preserves pending batches while downstream is busy" {
    var clock: Clock = .init(io);
    var input: Input = .{};
    input.init();
    var hold: Output.Hold = .{};
    var output: Output = .{ .hold = &hold };
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(2, .fromSeconds(60))).run, .{ clock.io(), &input, &output });
    defer _ = run.cancel(io) catch {};
    try input.send(1);
    try input.send(2);
    try hold.entered.wait(io);
    try output.expect(2, 1, 2);
    try input.send(3);
    try input.send(4);
    // The next push is released only after the worker takes the full batch.
    input.accepted.reset();
    try input.actions.putOne(io, .{ .item = 5 });
    try std.testing.expect(!input.accepted.isSet());
    clock.advanceTo(.fromSeconds(100));
    hold.released.set(io);
    try input.accepted.wait(io);
    try output.expect(2, 3, 4);
    try clock.waitingAt(.fromSeconds(160));
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 5, 5);
}

test "timed operators emit nothing for empty input" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        var clock: Clock = .init(io);
        var output: Output = .{};
        output.init();
        try zrx.program(zrx.range(u32, 0, 0), zrx.pipe(.{ op, zrx.forEach(Output.collect) })).run(.{ clock.io(), &output });
        var extra: [1]Result = undefined;
        try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
    }
}

test "batchWithin preserves every item and a program can run again" {
    const support = @import("support.zig");
    var seen: support.Recorder(u32) = .{};
    const work = zrx.program(zrx.range(u32, 0, 100), zrx.pipe(.{
        zrx.batchWithin(7, .fromSeconds(3600)),
        zrx.flatten(),
        zrx.forEach(support.record(u32)),
    }));
    for (0..2) |_| {
        seen.len = 0;
        try work.run(.{ io, &seen });
        try std.testing.expectEqual(@as(usize, 100), seen.len);
        for (seen.slice(), 0..) |item, index| try std.testing.expectEqual(@as(u32, @intCast(index)), item);
    }
}

fn RejectRun(comptime op: anytype) type {
    return struct {
        fn reject(_: anytype) error{Rejected}!void {
            return error.Rejected;
        }

        fn run(clock: Io, input: *Input) !void {
            try zrx.program(zrx.fromProducer(u32, Input.produce), zrx.pipe(.{ op, zrx.forEach(reject) })).run(.{ clock, input });
        }
    };
}

test "a timed worker failure interrupts an idle source" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        var clock: Clock = .init(io);
        var input: Input = .{};
        input.init();
        var run = try io.concurrent(RejectRun(op).run, .{ clock.io(), &input });
        defer _ = run.cancel(io) catch {};
        try input.send(1);
        try clock.waitingAt(.fromSeconds(60));
        clock.advanceTo(.fromSeconds(60));
        try std.testing.expectError(error.Rejected, run.await(io));
    }
}

test "timed operators stop at a done downstream and infer their errors" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(3600)), zrx.debounce(.fromSeconds(3600)) }) |op| {
        var output: Output = .{};
        output.init();
        const work = zrx.program(zrx.range(u32, 0, 1000), zrx.pipe(.{ op, zrx.take(1), zrx.forEach(Output.collect) }));
        try work.run(.{ io, &output });
        var extra: [1]Result = undefined;
        try std.testing.expectEqual(@as(usize, 1), try output.results.get(io, &extra, 0));
        try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));

        // A timer expiry is internal, so Timeout stays out of run's errors.
        const plain = zrx.program(zrx.fromValue(@as(u32, 1)), zrx.pipe(.{ op, zrx.drain() }));
        const E = @typeInfo(@TypeOf(plain.run(.{io}))).error_union.error_set;
        const names = comptime @typeInfo(E).error_set.error_names.?;
        try std.testing.expectEqual(@as(usize, 2), names.len);
        for (names) |name| {
            try std.testing.expect(std.mem.eql(u8, name, "Canceled") or std.mem.eql(u8, name, "ConcurrencyUnavailable"));
        }
    }
}

test "timed operators need concurrency and honor provided Io" {
    var backend: Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        const work = zrx.program(zrx.fromValue(@as(u32, 1)), zrx.pipe(.{ op, zrx.drain() }));
        try std.testing.expectError(error.ConcurrencyUnavailable, work.run(.{backend.io()}));
        try work.provide(.{io}).run(.{backend.io()});
    }
}
