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

                pub const zrx_boundary = {};

                pub fn init(self: *@This(), _: *const Op, env: Env) !void {
                    self.io = zrx.di.get(env, std.Io);
                    self.channel = .init(&self.buffer);
                    self.gate = if (gated) zrx.di.get(env, *RetireGate) else {};
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
                    while (true) {
                        const item = self.channel.getOne(self.io) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return error.Canceled,
                        };
                        if (try down.push(item) == .done) return;
                    }
                }

                pub fn retire(self: *@This()) void {
                    // Only the boundary's own task takes its time here; the
                    // run, retiring everyone at its end, must not wait.
                    if (gated and !self.gate.retiring.swap(true, .seq_cst)) {
                        if (self.gate.close_first) self.channel.close(self.io);
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
/// finished waiting (at the first join of a group, or at the first look at
/// its own cancellation, whichever it reaches first) until that task has
/// itself been asked to cancel, and leaves the request in place. For showing
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
        vtable.groupAwait = heldAwait;
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

    fn heldAwait(userdata: ?*anyopaque, group: *std.Io.Group, token: *anyopaque) std.Io.Cancelable!void {
        hold();
        return inner.vtable.groupAwait(userdata, group, token);
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
