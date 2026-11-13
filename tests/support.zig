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
    retiring: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
};

/// A task boundary written against the public contract only: a bounded
/// hand-over to a task of its own, as `queue` is. With a `*RetireGate` among
/// the dependencies it does not retire until the run has interrupted its
/// task.
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
                    if (gated) {
                        self.gate.retiring.store(true, .seq_cst);
                        while (!self.gate.interrupted.load(.seq_cst)) {
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

/// An `Io` that holds the first task to join another one (to await or cancel
/// a future) until that task has itself been asked to cancel, and leaves the
/// request in place. For showing what a task does about a request that
/// reaches it while it joins, without leaving that to the scheduler.
/// One at a time: its state is global.
pub const JoinHeld = struct {
    /// A task is being held at its join.
    pub var joining: std.atomic.Value(bool) = .init(false);

    var inner: std.Io = undefined;
    var vtable: std.Io.VTable = undefined;
    var armed: std.atomic.Value(bool) = .init(false);

    pub fn over(io: std.Io) std.Io {
        inner = io;
        vtable = io.vtable.*;
        vtable.await = heldAwait;
        vtable.cancel = heldCancel;
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

    fn heldAwait(userdata: ?*anyopaque, future: *std.Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
        hold();
        inner.vtable.await(userdata, future, result, alignment);
    }

    fn heldCancel(userdata: ?*anyopaque, future: *std.Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
        hold();
        inner.vtable.cancel(userdata, future, result, alignment);
    }
};
