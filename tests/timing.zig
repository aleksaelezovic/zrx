//! Timed operators, with input and clock advances controlled by the test.
const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const io = std.testing.io;

/// Only timed futex waits use the manual clock. A waiter registers before
/// checking the futex value, so a concurrent signal cannot be lost. Ordinary
/// waits, task startup and cancellation use the testing Io.
const Clock = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var time: std.atomic.Value(i64) = .init(0);
    var mutex: Io.Mutex = .init;
    var changed: Io.Event = .unset;
    var waiters: ?*Waiter = null;

    const Waiter = struct {
        ptr: *const u32,
        deadline: i96,
        ready: Io.Event = .unset,
        next: ?*Waiter,
    };

    fn start() Io {
        inner = io;
        vtable = inner.vtable.*;
        vtable.now = now;
        vtable.futexWait = wait;
        vtable.futexWake = wake;
        time.store(0, .seq_cst);
        mutex = .init;
        changed = .unset;
        std.debug.assert(waiters == null);
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        if (clock == .awake) return .fromNanoseconds(time.load(.seq_cst));
        return inner.vtable.now(userdata, clock);
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const deadline = switch (timeout) {
            .deadline => |at| if (at.clock == .awake) at.raw.nanoseconds else return inner.vtable.futexWait(userdata, ptr, expected, timeout),
            else => return inner.vtable.futexWait(userdata, ptr, expected, timeout),
        };
        var waiter: Waiter = .{ .ptr = ptr, .deadline = deadline, .next = null };
        mutex.lockUncancelable(inner);
        if (@atomicLoad(u32, ptr, .acquire) != expected or time.load(.seq_cst) >= deadline) {
            mutex.unlock(inner);
            return;
        }
        waiter.next = waiters;
        waiters = &waiter;
        changed.set(inner);
        mutex.unlock(inner);
        defer {
            mutex.lockUncancelable(inner);
            defer mutex.unlock(inner);
            var link = &waiters;
            while (link.*.? != &waiter) link = &link.*.?.next;
            link.* = waiter.next;
        }
        try waiter.ready.wait(inner);
    }

    fn wake(userdata: ?*anyopaque, ptr: *const u32, count: u32) void {
        mutex.lockUncancelable(inner);
        var it = waiters;
        while (it) |waiter| : (it = waiter.next) {
            if (waiter.ptr == ptr) waiter.ready.set(inner);
        }
        mutex.unlock(inner);
        inner.vtable.futexWake(userdata, ptr, count);
    }

    fn advance(seconds: i64) void {
        mutex.lockUncancelable(inner);
        defer mutex.unlock(inner);
        time.store(seconds * std.time.ns_per_s, .seq_cst);
        var it = waiters;
        while (it) |waiter| : (it = waiter.next) waiter.ready.set(inner);
    }

    fn waitingAt(seconds: i64) !void {
        while (true) {
            changed.reset();
            mutex.lockUncancelable(inner);
            var it = waiters;
            while (it) |waiter| : (it = waiter.next) {
                if (waiter.deadline == @as(i96, seconds) * std.time.ns_per_s and !waiter.ready.isSet()) {
                    mutex.unlock(inner);
                    return;
                }
            }
            mutex.unlock(inner);
            try changed.wait(inner);
        }
    }
};

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

test "batchWithin emits 900 of 1000 while the source is idle" {
    const clock = Clock.start();
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(1000, .fromSeconds(60))).run, .{ clock, &input, &output });
    defer _ = run.cancel(io) catch {};
    for (0..900) |index| try input.send(@intCast(index));
    try Clock.waitingAt(60);
    Clock.advance(60);
    try output.expect(900, 0, 899);
    try input.actions.putOne(io, .end);
    try run.await(io);
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "batchWithin keeps the first deadline and starts a new one after emission" {
    const clock = Clock.start();
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(3, .fromSeconds(60))).run, .{ clock, &input, &output });
    defer _ = run.cancel(io) catch {};
    // An empty batch has no deadline. Its first item arrives at t=100.
    Clock.advance(100);
    try input.send(1);
    try Clock.waitingAt(160);
    Clock.advance(130);
    try input.send(2);
    try Clock.waitingAt(160);
    Clock.advance(160);
    try output.expect(2, 1, 2);
    try input.send(3);
    try input.send(4);
    try input.send(5);
    try output.expect(3, 3, 5);
    Clock.advance(180);
    try input.send(6);
    try Clock.waitingAt(240);
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 6, 6);
}

test "debounce restarts its deadline and emits the latest item during source silence" {
    const clock = Clock.start();
    var input: Input = .{};
    input.init();
    var output: Output = .{};
    output.init();
    var run = try io.concurrent(Run(zrx.debounce(.fromSeconds(10))).run, .{ clock, &input, &output });
    defer _ = run.cancel(io) catch {};
    try input.send(1);
    try Clock.waitingAt(10);
    Clock.advance(5);
    try input.send(2);
    try Clock.waitingAt(15);
    Clock.advance(10);
    try Clock.waitingAt(15);
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
    Clock.advance(15);
    try output.expect(1, 2, 2);
    try input.send(3);
    try Clock.waitingAt(25);
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 3, 3);
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "timed operators propagate source failure and caller cancellation while waiting" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        inline for (.{ false, true }) |cancel| {
            const clock = Clock.start();
            var input: Input = .{};
            input.init();
            var output: Output = .{};
            output.init();
            var run = try io.concurrent(Run(op).run, .{ clock, &input, &output });
            defer _ = run.cancel(io) catch {};
            try input.send(1);
            try Clock.waitingAt(60);
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
    const clock = Clock.start();
    var input: Input = .{};
    input.init();
    var hold: Output.Hold = .{};
    var output: Output = .{ .hold = &hold };
    output.init();
    var run = try io.concurrent(Run(zrx.debounce(.fromSeconds(10))).run, .{ clock, &input, &output });
    defer _ = run.cancel(io) catch {};
    try input.send(1);
    try Clock.waitingAt(10);
    Clock.advance(10);
    try hold.entered.wait(io);
    try output.expect(1, 1, 1);
    Clock.advance(11);
    try input.send(2);
    Clock.advance(12);
    try input.send(3);
    Clock.advance(13);
    try input.send(4);
    Clock.advance(23);
    hold.released.set(io);
    try output.expect(1, 4, 4);
    try input.actions.putOne(io, .end);
    try run.await(io);
    var extra: [1]Result = undefined;
    try std.testing.expectEqual(@as(usize, 0), try output.results.get(io, &extra, 0));
}

test "batchWithin preserves pending batches while downstream is busy" {
    const clock = Clock.start();
    var input: Input = .{};
    input.init();
    var hold: Output.Hold = .{};
    var output: Output = .{ .hold = &hold };
    output.init();
    var run = try io.concurrent(Run(zrx.batchWithin(2, .fromSeconds(60))).run, .{ clock, &input, &output });
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
    Clock.advance(100);
    hold.released.set(io);
    try input.accepted.wait(io);
    try output.expect(2, 3, 4);
    try Clock.waitingAt(160);
    try input.actions.putOne(io, .end);
    try run.await(io);
    try output.expect(1, 5, 5);
}

test "timed operators emit nothing for empty input" {
    inline for (.{ zrx.batchWithin(3, .fromSeconds(60)), zrx.debounce(.fromSeconds(60)) }) |op| {
        const clock = Clock.start();
        var output: Output = .{};
        output.init();
        try zrx.program(zrx.range(u32, 0, 0), zrx.pipe(.{ op, zrx.forEach(Output.collect) })).run(.{ clock, &output });
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
        const clock = Clock.start();
        var input: Input = .{};
        input.init();
        var run = try io.concurrent(RejectRun(op).run, .{ clock, &input });
        defer _ = run.cancel(io) catch {};
        try input.send(1);
        try Clock.waitingAt(60);
        Clock.advance(60);
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
