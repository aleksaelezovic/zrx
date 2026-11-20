//! Shared test helpers.
const std = @import("std");
const zrx = @import("zrx");

/// A fixed-capacity log of the items a pipeline delivered.
pub fn Recorder(comptime T: type) type {
    return struct {
        items: [256]T = undefined,
        len: usize = 0,

        pub fn add(self: *@This(), item: T) void {
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }

        pub fn expect(self: *const @This(), expected: []const T) !void {
            try std.testing.expectEqualSlices(T, expected, self.slice());
        }
    };
}

/// A handler that appends each item to the injected `*Recorder(T)`.
pub fn record(comptime T: type) fn (*Recorder(T), T) void {
    return struct {
        fn add(recorder: *Recorder(T), item: T) void {
            recorder.add(item);
        }
    }.add;
}

/// Runs `runnable` and returns what it failed with. `run` itself returns
/// nothing: a failure goes to a rescue. This binds one that takes
/// everything, so a test can `try` a run or expect an error of it. A run
/// that is given a rescue of its own is not run through here.
pub fn run(runnable: anytype, deps: anytype) anyerror!void {
    var failure: Failure = .{};
    runnable.run(deps ++ .{ &failure, zrx.rescue(Failure.note) });
    if (failure.err) |err| return err;
}

/// What the rescue of `run` was given.
pub const Failure = struct {
    err: ?anyerror = null,

    fn note(failure: *Failure, err: anyerror) void {
        failure.err = err;
    }
};

/// Runs `runnable` and returns what was left for it to fail with. The rescue
/// bound here takes `anytype`, so it is given exactly the errors the run can
/// still fail with, and writes their names down when it does fail: a test of
/// what an operator takes away has to make the run fail with what is left.
pub fn runLeft(runnable: anytype, deps: anytype) Left {
    var left: Left = .{};
    runnable.run(deps ++ .{ &left, zrx.rescue(Left.note) });
    return left;
}

pub const Left = struct {
    text: [256]u8 = undefined,
    len: usize = 0,
    err: ?anyerror = null,

    fn note(left: *Left, err: anytype) void {
        const sorted = comptime sorted: {
            var list = @typeInfo(@TypeOf(err)).error_set.error_names.?[0..].*;
            for (1..list.len) |i| {
                var at = i;
                while (at > 0 and std.mem.lessThan(u8, list[at], list[at - 1])) : (at -= 1) {
                    std.mem.swap([:0]const u8, &list[at], &list[at - 1]);
                }
            }
            break :sorted list;
        };
        inline for (sorted) |error_name| {
            @memcpy(left.text[left.len..][0..error_name.len], error_name);
            left.text[left.len + error_name.len] = ' ';
            left.len += error_name.len + 1;
        }
        left.err = err;
    }

    /// The names of the errors the rescue could have been given, in
    /// alphabetical order, each followed by a space. Empty if the run did
    /// not fail.
    pub fn names(left: *const Left) []const u8 {
        return left.text[0..left.len];
    }
};

/// Observes the selected thread blocking on a mutex, then releases the
/// handler holding it. The test selects the thread immediately before its
/// downstream push, so no amount of scheduler delay substitutes for a wait.
pub const GateWait = struct {
    pub var thread: std.atomic.Value(std.Thread.Id) = .init(0);
    pub var waiting: std.atomic.Value(bool) = .init(false);
    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var release: *std.Io.Event = undefined;
    var armed: std.atomic.Value(bool) = .init(false);

    pub fn over(io: std.Io, event: *std.Io.Event) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.futexWait = wait;
        release = event;
        thread.store(0, .seq_cst);
        waiting.store(false, .seq_cst);
        armed.store(true, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (std.Thread.getCurrentId() == thread.load(.seq_cst) and armed.swap(false, .seq_cst)) {
            waiting.store(true, .seq_cst);
            release.set(inner);
        }
        return inner.vtable.futexWait(userdata, ptr, expected, timeout);
    }
};

pub const TaskStarts = struct {
    pub var count: std.atomic.Value(usize) = .init(0);
    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.groupConcurrent = start;
        count.store(0, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn start(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, function: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
        _ = count.fetchAdd(1, .seq_cst);
        return inner.vtable.groupConcurrent(userdata, group, context, alignment, function);
    }
};

/// Makes the queue and coordinator waits depend on retirement, even if a
/// cancellation request is not observed at those waits.
pub const UncancelableWaits = struct {
    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.futexWait = wait;
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
        inner.vtable.futexWaitUncancelable(userdata, ptr, expected);
    }
};

/// For a single concurrent boundary: hold auxiliary launches until its
/// coordinator waits. The source has empty input and cannot be that waiter.
pub const WorkersAfterWait = struct {
    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var starts: std.atomic.Value(usize) = .init(0);
    var waiting: std.atomic.Value(bool) = .init(false);

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.groupConcurrent = start;
        vtable.futexWait = wait;
        starts.store(0, .seq_cst);
        waiting.store(false, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn start(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, function: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
        if (starts.fetchAdd(1, .seq_cst) == 2) {
            while (!waiting.load(.seq_cst)) std.Thread.yield() catch {};
        }
        return inner.vtable.groupConcurrent(userdata, group, context, alignment, function);
    }

    fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        waiting.store(true, .seq_cst);
        return inner.vtable.futexWait(userdata, ptr, expected, timeout);
    }
};

/// What a `handoff` waits on while it retires, when a test wants it to take
/// its time there.
pub const RetireGate = struct {
    /// Let go of whoever waits on the boundary first, then take the time.
    close_first: bool = false,
    retiring: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
    /// Set by the test to end the wait without an interruption.
    released: std.atomic.Value(bool) = .init(false),
};

/// A task boundary written against the public contract only: a bounded
/// hand-over to a task of its own, as `queue` is. With a `*RetireGate` among
/// the dependencies it takes its time retiring: until the run has
/// interrupted its task, or the gate is released.
pub fn handoff(comptime capacity: usize) Handoff(capacity) {
    return .{};
}

fn Handoff(comptime capacity: usize) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "handoff";

        pub fn Out(comptime _: type, comptime In: type) type {
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const gated = zrx.di.has(Env, *RetireGate);
            return struct {
                io: std.Io,
                buffer: [capacity]In,
                channel: std.Io.Queue(In),
                gate: if (gated) *RetireGate else void,
                /// The thread that runs `work`.
                worker: std.atomic.Value(std.Thread.Id),

                pub const zrx_boundary = {};

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.io = zrx.di.get(env, std.Io);
                    self.channel = .init(&self.buffer);
                    self.gate = if (gated) zrx.di.get(env, *RetireGate) else {};
                    self.worker = .init(0);
                }

                pub fn taskIo(self: *@This()) std.Io {
                    return self.io;
                }

                pub fn push(self: *@This(), item: In, _: anytype) !zrx.Flow {
                    self.channel.putOne(self.io, item) catch |err| switch (err) {
                        error.Closed => return .done,
                        error.Canceled => return error.Canceled,
                    };
                    return .more;
                }

                pub fn finish(self: *@This(), _: anytype) !void {
                    self.channel.close(self.io);
                }

                pub fn work(self: *@This(), down: anytype) !void {
                    self.worker.store(std.Thread.getCurrentId(), .seq_cst);
                    while (true) {
                        const item = self.channel.getOne(self.io) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return error.Canceled,
                        };
                        if (try down.push(item) == .done) return;
                    }
                }

                pub fn retire(self: *@This()) void {
                    // Only the boundary's own task takes its time here. The
                    // run retires everyone at its end, from its own task,
                    // and must not wait.
                    if (gated and std.Thread.getCurrentId() == self.worker.load(.seq_cst)) {
                        if (self.gate.close_first) self.channel.close(self.io);
                        self.gate.retiring.store(true, .seq_cst);
                        while (!self.gate.interrupted.load(.seq_cst) and !self.gate.released.load(.seq_cst)) {
                            self.io.checkCancel() catch self.gate.interrupted.store(true, .seq_cst);
                            std.Thread.yield() catch {};
                        }
                    }
                    self.channel.close(self.io);
                }
            };
        }
    };
}

/// An `Io` that holds the task which supervises a run where that run has
/// finished waiting (at its first join of a group, or at its look at its own
/// cancellation if no task is left to join) until that task has itself been
/// asked to cancel, and leaves the request in place. For showing
/// what a run does about a request that reaches its caller that late,
/// without leaving it to the scheduler. One at a time: its state is global.
pub const JoinHeld = struct {
    /// A task is being held.
    pub var joining: std.atomic.Value(bool) = .init(false);

    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var armed: std.atomic.Value(bool) = .init(false);

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.groupCancel = heldCancel;
        vtable.checkCancel = heldCheck;
        joining.store(false, .seq_cst);
        armed.store(true, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn hold() void {
        if (!armed.swap(false, .seq_cst)) return;
        joining.store(true, .seq_cst);
        while (true) {
            inner.checkCancel() catch {
                inner.recancel();
                return;
            };
            std.Thread.yield() catch {};
        }
    }

    fn heldCancel(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) void {
        hold();
        inner.vtable.groupCancel(userdata, group, token);
    }

    fn heldCheck(userdata: ?*anyopaque) std.Io.Cancelable!void {
        hold();
        return inner.vtable.checkCancel(userdata);
    }
};

/// An `Io` that holds the first positional file write until the task making
/// it has been asked to cancel, leaves the request in place, and then lets
/// the write go ahead, where `std` turns the request into a failed write.
/// One at a time: its state is global.
pub const WriteHeld = struct {
    /// A task is being held at its write.
    pub var writing: std.atomic.Value(bool) = .init(false);

    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var armed: std.atomic.Value(bool) = .init(false);

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.fileWritePositional = heldWrite;
        writing.store(false, .seq_cst);
        armed.store(true, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn heldWrite(
        userdata: ?*anyopaque,
        file: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
        offset: u64,
    ) std.Io.File.WritePositionalError!usize {
        if (armed.swap(false, .seq_cst)) {
            writing.store(true, .seq_cst);
            while (true) {
                inner.checkCancel() catch {
                    inner.recancel();
                    break;
                };
                std.Thread.yield() catch {};
            }
        }
        return inner.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
    }
};

/// An `Io` whose positional file reads fail with `error.InputOutput`, for
/// showing what a source makes of a read that fails.
pub const ReadFails = struct {
    var vtable: std.Io.VTable = undefined;

    pub fn over(io: std.Io) std.Io {
        vtable = io.vtable.*;
        vtable.fileReadPositional = fail;
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn fail(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
        return error.InputOutput;
    }
};

/// An `Io` that holds the `nth` start of a task in a group until the task
/// starting it has been asked to cancel, and leaves the request in place.
/// One at a time: its state is global.
pub const LaunchHeld = struct {
    /// A task is being held while it starts another.
    pub var launching: std.atomic.Value(bool) = .init(false);

    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var remaining: std.atomic.Value(usize) = .init(0);

    pub fn over(io: std.Io, nth: usize) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.groupConcurrent = heldConcurrent;
        launching.store(false, .seq_cst);
        remaining.store(nth, .seq_cst);
        return .{ .userdata = io.userdata, .vtable = &vtable };
    }

    fn heldConcurrent(
        userdata: ?*anyopaque,
        group: *std.Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) std.Io.ConcurrentError!void {
        if (remaining.load(.seq_cst) != 0 and remaining.fetchSub(1, .seq_cst) == 1) {
            launching.store(true, .seq_cst);
            while (true) {
                inner.checkCancel() catch {
                    inner.recancel();
                    break;
                };
                std.Thread.yield() catch {};
            }
        }
        return inner.vtable.groupConcurrent(userdata, group, context, context_alignment, start);
    }
};
