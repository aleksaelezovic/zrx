//! `zrx.ext.time`: a ticking source, a time for each item and a throttle,
//! with the time on a clock the test moves. Nothing here waits a length of
//! time: a test waits until the source is in its timed wait, or lets a
//! handler set the time an item arrives at.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const time = zrx.ext.time;
const Io = std.Io;
const io = std.testing.io;

const Clock = zrx.testing.Clock;

// --- ticks ------------------------------------------------------------------

/// Where the ticks of a run arrive, and where its pipe can be held at work.
const Seen = struct {
    slots: [8]u64 = undefined,
    ticks: Io.Queue(u64) = undefined,
    hold: ?*Hold = null,

    /// The handler does not return for the first tick until this is set.
    const Hold = struct { released: Io.Event = .unset };

    fn init(self: *Seen) void {
        self.ticks = .init(&self.slots);
    }

    fn collect(self: *Seen, tick: u64) !void {
        try self.ticks.putOne(io, tick);
        if (self.hold) |hold| {
            self.hold = null;
            try hold.released.wait(io);
        }
    }

    fn expect(self: *Seen, tick: u64) !void {
        try std.testing.expectEqual(tick, try self.ticks.getOne(io));
    }

    /// What has arrived so far is `tick` and nothing else. Does not wait.
    fn expectOnly(self: *Seen, tick: u64) !void {
        var arrived: [2]u64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try self.ticks.get(io, &arrived, 0));
        try std.testing.expectEqual(tick, arrived[0]);
    }

    fn expectNone(self: *Seen) !void {
        var extra: [1]u64 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try self.ticks.get(io, &extra, 0));
    }
};

const every_ten = time.ticks(.fromSeconds(10));

fn countThree(timed: Io, seen: *Seen) !void {
    try support.run(zrx.program(every_ten, .{
        zrx.take(3),
        zrx.forEach(Seen.collect),
    }), .{ timed, seen });
}

fn countOn(timed: Io, seen: *Seen) !void {
    try support.run(zrx.program(every_ten, .{zrx.forEach(Seen.collect)}), .{ timed, seen });
}

test "ticks pushes a count every period, the first a period after it starts, until it is answered done" {
    var clock: Clock = .init(io);
    clock.advanceTo(.fromSeconds(7));
    var seen: Seen = .{};
    seen.init();
    var run = try io.concurrent(countThree, .{ clock.io(), &seen });
    defer _ = run.cancel(io) catch {};

    try clock.waitingAt(.fromSeconds(17));
    try seen.expectNone();
    // Not due yet: the wait is left asleep.
    clock.advanceTo(.fromSeconds(16));
    try clock.waitingAt(.fromSeconds(17));
    try seen.expectNone();
    clock.advanceTo(.fromSeconds(17));
    try seen.expect(0);
    try clock.waitingAt(.fromSeconds(27));
    clock.advanceTo(.fromSeconds(27));
    try seen.expect(1);
    try clock.waitingAt(.fromSeconds(37));
    clock.advanceTo(.fromSeconds(37));
    try seen.expect(2);
    // `take(3)` answered `.done`: the source ends without another wait.
    try run.await(io);
    try seen.expectNone();
}

test "a tick that comes due while the pipe is at work is skipped, and the times do not drift" {
    var clock: Clock = .init(io);
    var hold: Seen.Hold = .{};
    var seen: Seen = .{ .hold = &hold };
    seen.init();
    var run = try io.concurrent(countOn, .{ clock.io(), &seen });
    defer _ = run.cancel(io) catch {};

    try clock.waitingAt(.fromSeconds(10));
    clock.advanceTo(.fromSeconds(10));
    try seen.expect(0);
    // The pipe is at work on tick 0 while ticks 1 and 2 come due.
    clock.advanceTo(.fromSeconds(35));
    hold.released.set(io);
    // The next is tick 3 at its own time, 40 and not 45, and nothing was
    // pushed to catch up.
    try clock.waitingAt(.fromSeconds(40));
    try seen.expectNone();
    clock.advanceTo(.fromSeconds(40));
    try seen.expect(3);
    try clock.waitingAt(.fromSeconds(50));
    try seen.expectNone();
}

test "a tick that is due just as the pipe gets back to the source is pushed, not skipped" {
    var clock: Clock = .init(io);
    var hold: Seen.Hold = .{};
    var seen: Seen = .{ .hold = &hold };
    seen.init();
    var run = try io.concurrent(countOn, .{ clock.io(), &seen });
    defer _ = run.cancel(io) catch {};

    try clock.waitingAt(.fromSeconds(10));
    clock.advanceTo(.fromSeconds(10));
    try seen.expect(0);
    clock.advanceTo(.fromSeconds(20));
    hold.released.set(io);
    // Tick 1 was due at 20 and is there before the source waits for tick 2.
    try clock.waitingAt(.fromSeconds(30));
    try seen.expectOnly(1);
}

/// The `Io` of a clock, whose first timed wait returns at once, as a wake
/// that nobody meant does. One at a time: its state is global.
const WokenEarly = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var armed: std.atomic.Value(bool) = .init(false);
    var woken: Io.Event = .unset;

    fn over(timed: Io) Io {
        inner = timed;
        vtable = timed.vtable.*;
        vtable.futexWait = wait;
        woken = .unset;
        armed.store(true, .seq_cst);
        return .{ .userdata = timed.userdata, .vtable = &vtable };
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        if (timeout != .none and armed.swap(false, .seq_cst)) {
            woken.set(io);
            return;
        }
        return inner.vtable.futexWait(userdata, ptr, expected, timeout);
    }
};

test "ticks woken before its time looks at the clock and waits again" {
    var clock: Clock = .init(io);
    var seen: Seen = .{};
    seen.init();
    var run = try io.concurrent(countOn, .{ WokenEarly.over(clock.io()), &seen });
    defer _ = run.cancel(io) catch {};

    try WokenEarly.woken.wait(io);
    try clock.waitingAt(.fromSeconds(10));
    try seen.expectNone();
    clock.advanceTo(.fromSeconds(10));
    try seen.expect(0);
}

const hourly = time.ticks(.fromSeconds(3600));

fn firstBehindQueue(timed: Io, seen: *Seen) !void {
    try support.run(zrx.program(hourly, .{
        zrx.queue(1),
        zrx.take(1),
        zrx.forEach(Seen.collect),
    }), .{ timed, seen });
}

test "ticks ends where it waits once its consumers behind a boundary are done" {
    var clock: Clock = .init(io);
    var seen: Seen = .{};
    seen.init();
    var run = try io.concurrent(firstBehindQueue, .{ clock.io(), &seen });
    defer _ = run.cancel(io) catch {};

    try clock.waitingAt(.fromSeconds(3600));
    clock.advanceTo(.fromSeconds(3600));
    // The second tick is an hour away and the clock stands still: the run
    // is over because the source was told that nobody takes it.
    try run.await(io);
    try seen.expect(0);
    try seen.expectNone();
}

test "ticks merged with a source that ends does not hold a run whose pipe is done" {
    // Behind the queue the source is told through `Stop`; without one the
    // merge interrupts it where it waits. The clock stands still in both.
    const behind_queue = zrx.pipe(.{
        zrx.queue(1),
        zrx.take(1),
        zrx.forEach(Seen.collect),
    });
    const direct = zrx.pipe(.{
        zrx.take(1),
        zrx.forEach(Seen.collect),
    });
    inline for (.{ behind_queue, direct }) |work| {
        var clock: Clock = .init(io);
        var seen: Seen = .{};
        seen.init();
        try support.run(zrx.program(zrx.merge(.{ zrx.fromValue(@as(u64, 99)), hourly }), work), .{ clock.io(), &seen });
        try seen.expect(99);
        try seen.expectNone();
    }
}

fn leftOf(timed: Io) support.Left {
    return support.runLeft(zrx.program(every_ten, .{zrx.drain()}), .{timed});
}

test "a request to cancel interrupts ticks where it waits, and is all the source can fail with" {
    var clock: Clock = .init(io);
    var run = try io.concurrent(leftOf, .{clock.io()});
    try clock.waitingAt(.fromSeconds(10));
    const left = run.cancel(io);
    try std.testing.expectEqualStrings("Canceled ", left.names());
    try std.testing.expectEqual(error.Canceled, left.err.?);
}

// --- stamp and throttle -------------------------------------------------------

/// An item and the time the test has it arrive at, in milliseconds.
const Arrival = struct { at: i64, value: u32 };

fn arrive(clock: *Clock, arrival: Arrival) void {
    clock.advanceTo(.fromMilliseconds(arrival.at));
}

const Stamped = time.Stamped(u32);

test "stamp(.awake) pairs each item with the time on the Io of the run" {
    var clock: Clock = .init(io);
    var seen: support.Recorder(Stamped) = .{};
    const arrivals = [_]Arrival{ .{ .at = 5, .value = 1 }, .{ .at = 5, .value = 2 }, .{ .at = 1500, .value = 3 } };
    zrx.program(zrx.fromSlice(&arrivals), .{
        zrx.tap(arrive),
        zrx.map(zrx.field(.value)),
        zrx.map(time.stamp(.awake)),
        zrx.forEach(support.record(Stamped)),
    }).run(.{ clock.io(), &clock, &seen });
    try std.testing.expectEqual(@as(usize, 3), seen.len);
    for (seen.slice(), arrivals) |stamped, arrival| {
        try std.testing.expectEqual(arrival.value, stamped.item);
        try std.testing.expectEqual(arrival.at, stamped.at.toMilliseconds());
    }
}

/// An `Io` whose `.real` clock says what the test set. One at a time.
const RealAt = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var seconds: i64 = 0;

    fn over(base: Io, at: i64) Io {
        inner = base;
        vtable = base.vtable.*;
        vtable.now = now;
        seconds = at;
        return .{ .userdata = base.userdata, .vtable = &vtable };
    }

    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        if (clock == .real) return Io.Timestamp.zero.addDuration(.fromSeconds(seconds));
        return inner.vtable.now(userdata, clock);
    }
};

test "stamp reads the clock it is given" {
    var clock: Clock = .init(io);
    clock.advanceTo(.fromSeconds(3));
    var seen: support.Recorder(Stamped) = .{};
    const work = zrx.program(zrx.fromValue(@as(u32, 7)), .{
        zrx.branch(.{
            .{
                zrx.map(time.stamp(.real)),
                zrx.forEach(support.record(Stamped)),
            },
            .{
                zrx.map(time.stamp(.awake)),
                zrx.forEach(support.record(Stamped)),
            },
        }),
    });
    work.run(.{ RealAt.over(clock.io(), 1_700_000_000), &seen });
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), seen.items[0].at.toSeconds());
    try std.testing.expectEqual(@as(i64, 3), seen.items[1].at.toSeconds());
}

const window = time.throttle(.fromMilliseconds(100));

test "throttle passes an item, drops what follows within the window and keeps nothing for the end" {
    var clock: Clock = .init(io);
    var seen: support.Recorder(u32) = .{};
    const arrivals = [_]Arrival{
        .{ .at = 0, .value = 1 }, // the first passes
        .{ .at = 50, .value = 2 },
        .{ .at = 99, .value = 3 },
        .{ .at = 100, .value = 4 }, // as the window ends; the two dropped did not extend it
        .{ .at = 199, .value = 5 },
        .{ .at = 260, .value = 6 }, // a window starts with the item, not on a grid
        .{ .at = 300, .value = 7 },
        .{ .at = 359, .value = 8 },
        .{ .at = 360, .value = 9 },
        .{ .at = 400, .value = 10 }, // the last of a burst is dropped
    };
    zrx.program(zrx.fromSlice(&arrivals), .{
        zrx.tap(arrive),
        window,
        zrx.map(zrx.field(.value)),
        zrx.forEach(support.record(u32)),
    }).run(.{ clock.io(), &clock, &seen });
    try seen.expect(&.{ 1, 4, 6, 9 });
}

fn countArrival(count: *usize, _: Arrival) void {
    count.* += 1;
}

test "throttle answers done as the pipe after it does" {
    var clock: Clock = .init(io);
    var seen: support.Recorder(u32) = .{};
    var pushed: usize = 0;
    const arrivals = [_]Arrival{
        .{ .at = 0, .value = 1 },
        .{ .at = 10, .value = 2 },
        .{ .at = 100, .value = 3 },
        .{ .at = 200, .value = 4 },
        .{ .at = 300, .value = 5 },
    };
    zrx.program(zrx.fromSlice(&arrivals), .{
        zrx.tap(arrive),
        zrx.tap(countArrival),
        window,
        zrx.take(2),
        zrx.map(zrx.field(.value)),
        zrx.forEach(support.record(u32)),
    }).run(.{ clock.io(), &clock, &seen, &pushed });
    try seen.expect(&.{ 1, 3 });
    try std.testing.expectEqual(@as(usize, 3), pushed);
}

test "throttle starts every run open, and each sub-pipe has a window of its own" {
    var clock: Clock = .init(io);
    var seen: support.Recorder(u32) = .{};
    const Marked = struct { at: i64, value: u32, urgent: bool };
    const markedArrive = struct {
        fn call(timed: *Clock, marked: Marked) void {
            timed.advanceTo(.fromMilliseconds(marked.at));
        }
    }.call;
    const routed = .{
        zrx.tap(markedArrive),
        zrx.route(.{
            zrx.when(zrx.field(.urgent), .{window}),
            zrx.otherwise(.{window}),
        }),
        zrx.map(zrx.field(.value)),
        zrx.forEach(support.record(u32)),
    };
    const first = [_]Marked{
        .{ .at = 0, .value = 1, .urgent = false },
        .{ .at = 10, .value = 2, .urgent = true }, // the other case's window is not this one's
        .{ .at = 20, .value = 3, .urgent = false },
        .{ .at = 30, .value = 4, .urgent = true },
    };
    const second = [_]Marked{
        .{ .at = 40, .value = 5, .urgent = false }, // within 100 ms of the first run's item
        .{ .at = 50, .value = 6, .urgent = false },
    };
    zrx.program(zrx.fromSlice(&first), routed).run(.{ clock.io(), &clock, &seen });
    try seen.expect(&.{ 1, 2 });
    zrx.program(zrx.fromSlice(&second), routed).run(.{ clock.io(), &clock, &seen });
    try seen.expect(&.{ 1, 2, 5 });
}
