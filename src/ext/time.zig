//! Time for the items of a pipe, on top of the clocks of `std.Io`.
//!
//!     const heartbeat = program(time.ticks(.fromSeconds(30)), .{
//!         map(time.stamp(.real)),
//!         forEach(report),
//!     });
//!
//!     const alerts = pipe(.{
//!         time.throttle(.fromSeconds(5)),
//!         forEach(notify),
//!     });
//!
//! `ticks` is a source, `stamp` a handler and `throttle` a synchronous
//! operator: none of them starts a task or keeps an item. An operator that
//! holds an item until a deadline needs a task boundary, and those are in
//! the core: `debounce` and `batchWithin`.
//!
//! Nothing here is known to the core: these are written against the source,
//! handler and operator contracts, and take the time from the `std.Io` the
//! run was given.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Stop = @import("../completion.zig").Stop;
const Flow = core.Flow;

/// The clock `ticks` and `throttle` measure with, as `batchWithin` and
/// `debounce` do: it does not count the time the system is suspended.
const measured: Io.Clock = .awake;

/// A source that pushes a count every `period`: 0 one period after it
/// starts, 1 a period after that. The times are fixed when it starts, so a
/// pipe that takes its time does not make them drift. A tick whose time has
/// passed when the pipe gets back to the source is skipped: nothing is
/// caught up, and its number is missing from the count.
///
/// It ends when a push answers `.done`, and where it waits when its
/// consumers behind a task boundary are done (`zrx.Stop`). Needs `std.Io`.
pub fn ticks(comptime period: Io.Duration) Ticks(period) {
    return .{};
}

fn Ticks(comptime period: Io.Duration) type {
    if (period.nanoseconds <= 0) @compileError("time.ticks: period must be positive; pass e.g. `.fromSeconds(1)`");
    return struct {
        pub const zrx_source = {};
        pub const zrx_stop_source = true;
        pub const Item = u64;

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            const Env = @TypeOf(env);
            if (comptime !di.has(Env, Io)) @compileError("time.ticks: needs `std.Io` to wait for its period; pass `io` to `run(.{ io, ... })`");
            const io = di.get(env, Io);
            // Whoever runs a source that asks for `Stop` provides one. A
            // wrapper that does not is answered through its pushes alone.
            const stop: Stop = if (comptime di.has(Env, Stop)) di.get(env, Stop) else .{};

            var tick: u64 = 0;
            var due = measured.now(io).addDuration(period);
            while (true) {
                while (true) {
                    if (stop.requested()) return;
                    if (measured.now(io).nanoseconds >= due.nanoseconds) break;
                    // A wake that is neither the stop nor the deadline is
                    // reported as a timeout as well: look at both again.
                    stop.waitTimeout(io, .{ .deadline = due.withClock(measured) }) catch |err| switch (err) {
                        error.Timeout => {},
                        error.Canceled => return error.Canceled,
                    };
                }
                if (try down.push(tick) == .done) return;
                // The next tick is the first whose time has not passed.
                const late = due.durationTo(measured.now(io)).nanoseconds;
                const periods: i96 = if (late <= period.nanoseconds) 1 else @divFloor(late - 1, period.nanoseconds) + 1;
                tick += @intCast(periods);
                due = due.addDuration(.{ .nanoseconds = periods * period.nanoseconds });
            }
        }
    };
}

/// An item and the time it was stamped at: what `map(stamp(clock))` emits.
pub fn Stamped(comptime T: type) type {
    return struct { at: Io.Timestamp, item: T };
}

/// A handler that pairs an item with the time on `clock`, read from the
/// `std.Io` of the run: `map(time.stamp(.real))`. `.real` is the time of
/// day, as nanoseconds since 1970; `.awake` only goes forward and is the
/// one to measure with.
pub fn stamp(comptime clock: Io.Clock) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{Io};
        }

        pub fn call(env: anytype, args: anytype) Stamped(@TypeOf(args[0])) {
            return .{ .at = clock.now(di.get(env, Io)), .item = args[0] };
        }
    };
}

/// Passes an item and then drops the ones that arrive within `window` of
/// it. The window starts with an item that passed, so a dropped item does
/// not extend it, and an item that arrives as the window ends passes.
/// Nothing is kept: the last item of a burst is dropped, where `debounce`
/// would emit it. Reads the clock once per item. Needs `std.Io`.
pub fn throttle(comptime window: Io.Duration) Throttle(window) {
    return .{};
}

/// A time kept between items. `std.Io` counts nanoseconds in 96 bits, and
/// a stage's state is reached through a pointer, where such an integer is
/// kept extended to 128. In 64 it is one register, and good for 292 years
/// of a clock that starts when the system does.
const Nanoseconds = i64;

fn Throttle(comptime window: Io.Duration) type {
    if (window.nanoseconds <= 0) @compileError("time.throttle: window must be positive; pass e.g. `.fromSeconds(1)`");
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "time.throttle";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (!di.has(Env, Io)) @compileError("time.throttle: needs `std.Io` to read the clock; pass `io` to `run(.{ io, ... })`");
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                io: Io,
                /// When the window of the last item that passed ends, in
                /// nanoseconds on the clock. No time is earlier than the
                /// one it starts with.
                open_at: Nanoseconds,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .io = di.get(env, Io), .open_at = std.math.minInt(Nanoseconds) };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    const now: Nanoseconds = @intCast(measured.now(self.io).nanoseconds);
                    if (now < self.open_at) return .more;
                    self.open_at = now + @as(Nanoseconds, @intCast(window.nanoseconds));
                    return down.push(item);
                }
            };
        }
    };
}
