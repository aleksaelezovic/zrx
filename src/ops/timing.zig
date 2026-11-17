//! Time-based buffering, on a task of its own using the boundary contract.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Batch = @import("transform.zig").Batch;

/// Emits up to `size` items when full or when `max_age` has elapsed since
/// the first item entered the batch. Requires `std.Io` and starts a task.
pub fn batchWithin(comptime size: usize, comptime max_age: Io.Duration) Timed(.batch, size, max_age) {
    return .{};
}

/// Emits the latest item after `quiet` without another push. Normal input
/// end emits a pending item immediately. Requires `std.Io` and starts a task.
pub fn debounce(comptime quiet: Io.Duration) Timed(.debounce, 1, quiet) {
    return .{};
}

const Mode = enum { batch, debounce };

fn Timed(comptime mode: Mode, comptime size: usize, comptime duration: Io.Duration) type {
    const who = if (mode == .batch) "batchWithin" else "debounce";
    if (size == 0) @compileError(who ++ ": size must be at least 1; pass a positive comptime size");
    if (duration.nanoseconds <= 0) @compileError(who ++ ": duration must be positive; pass e.g. `.fromSeconds(1)`");
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = who;

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (!di.has(Env, Io)) @compileError(who ++ ": needs `std.Io` to run its timer task; pass `io` to `run(.{ io, ... })`");
            return if (mode == .batch) Batch(In, size) else In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Output = Out(Env, In);
            return struct {
                io: Io,
                mutex: Io.Mutex,
                changed: Io.Condition,
                items: [size]In,
                len: usize,
                deadline: Io.Clock.Timestamp,
                closed: bool,

                const Self = @This();
                pub const zrx_boundary = {};

                pub fn init(self: *Self, _: *const Op, env: Env) void {
                    self.io = di.get(env, Io);
                    self.mutex = .init;
                    self.changed = .init;
                    self.items = undefined;
                    self.len = 0;
                    self.deadline = undefined;
                    self.closed = false;
                }

                pub fn taskIo(self: *Self) Io {
                    return self.io;
                }

                pub fn push(self: *Self, item: In, _: anytype) !core.Flow {
                    try self.mutex.lock(self.io);
                    defer self.mutex.unlock(self.io);
                    if (mode == .batch) {
                        while (self.len == size and !self.closed) try self.changed.wait(self.io, &self.mutex);
                    }
                    if (self.closed) return .done;
                    if (mode == .debounce or self.len == 0) {
                        self.deadline = .fromNow(self.io, .{ .raw = duration, .clock = .awake });
                    }
                    if (mode == .batch) {
                        self.items[self.len] = item;
                        self.len += 1;
                    } else {
                        self.items[0] = item;
                        self.len = 1;
                    }
                    self.changed.broadcast(self.io);
                    return .more;
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    self.retire();
                }

                pub fn work(self: *Self, down: anytype) !void {
                    while (try self.next()) |item| {
                        if (try down.push(item) == .done) return;
                    }
                }

                fn next(self: *Self) Io.Cancelable!?Output {
                    try self.mutex.lock(self.io);
                    defer self.mutex.unlock(self.io);
                    while (true) {
                        if (self.len == 0) {
                            if (self.closed) return null;
                            try self.changed.wait(self.io, &self.mutex);
                            continue;
                        }
                        if (self.closed or (mode == .batch and self.len == size) or
                            self.deadline.untilNow(self.io).raw.nanoseconds >= 0)
                        {
                            const item: Output = if (mode == .batch)
                                .{ .items = self.items, .len = self.len }
                            else
                                self.items[0];
                            self.len = 0;
                            self.changed.broadcast(self.io);
                            return item;
                        }
                        self.changed.waitTimeout(self.io, &self.mutex, .{ .deadline = self.deadline }) catch |err| switch (err) {
                            // A signal can also arrive with an expired deadline.
                            // Recheck both the pending data and the clock.
                            error.Timeout => {},
                            error.Canceled => return error.Canceled,
                        };
                    }
                }

                pub fn retire(self: *Self) void {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.closed = true;
                    self.changed.broadcast(self.io);
                }
            };
        }
    };
}
