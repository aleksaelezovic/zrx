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

/// A time or a length of it as `ticks` and `throttle` count: nanoseconds
/// from 0 to `limit`. `std.Io` counts in 96 bits, and a stage's state is
/// reached through a pointer, where such an integer is kept extended to
/// 128. In 64 it is one register. No two of these make a sum that does not
/// fit, so what is checked is only that each is within the range: a
/// reading by `reading`, a period or window by `span`.
const Nanoseconds = u64;

/// As far as time is counted here: 292 years of a clock that starts when
/// the system does.
const limit: Nanoseconds = std.math.maxInt(u63);

/// The clock, read as a time within the range: one outside it counts as
/// the nearest end. Past the limit the clock stands still, so a time later
/// than the limit never comes.
fn reading(io: Io) Nanoseconds {
    return std.math.lossyCast(u63, measured.now(io).nanoseconds);
}

/// A period or a window as a count: positive, and within the range.
fn span(comptime what: []const u8, comptime length: Io.Duration) Nanoseconds {
    if (length.nanoseconds <= 0) @compileError(what ++ " must be positive; pass e.g. `.fromSeconds(1)`");
    if (length.nanoseconds > limit) @compileError(std.fmt.comptimePrint(
        "{s} of {d} ns is longer than time is counted here, 2^63 ns (about 292 years); pass a shorter one",
        .{ what, length.nanoseconds },
    ));
    return @intCast(length.nanoseconds);
}

/// A source that pushes a count every `period`: 0 one period after it
/// starts, 1 a period after that. The times are fixed when it starts, so a
/// pipe that takes its time does not make them drift. A tick whose time has
/// passed when the pipe gets back to the source is skipped: nothing is
/// caught up, and its number is missing from the count. A tick due later
/// than time is counted (`limit`) never comes: the source waits to be
/// stopped.
///
/// It ends when a push answers `.done`, and where it waits when its
/// consumers behind a task boundary are done (`zrx.Stop`). Needs `std.Io`.
pub fn ticks(comptime period: Io.Duration) Ticks(period) {
    return .{};
}

fn Ticks(comptime period: Io.Duration) type {
    const length = span("time.ticks: period", period);
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

            // A time that never comes is waited for like any other: until
            // the consumers are done, or the run is cancelled.
            var tick: u64 = 0;
            var due = after(reading(io), 1) orelse return stop.wait(io);
            while (true) {
                while (true) {
                    if (stop.requested()) return;
                    if (reading(io) >= due) break;
                    // A wake that is neither the stop nor the deadline is
                    // reported as a timeout as well: look at both again.
                    stop.waitTimeout(io, .{ .deadline = Io.Timestamp.fromNanoseconds(due).withClock(measured) }) catch |err| switch (err) {
                        error.Timeout => {},
                        error.Canceled => return error.Canceled,
                    };
                }
                if (try down.push(tick) == .done) return;
                // The next tick is the first whose time has not passed.
                const late = reading(io) -| due;
                const periods = if (late <= length) 1 else (late - 1) / length + 1;
                due = after(due, periods) orelse return stop.wait(io);
                tick += periods;
            }
        }

        /// The time `periods` periods after `from`, or null where that is
        /// later than the limit. The count needs no such check: it is the
        /// number of periods between two times within the range.
        fn after(from: Nanoseconds, periods: u64) ?Nanoseconds {
            const at = @as(u128, from) + @as(u128, periods) * length;
            return if (at > limit) null else @intCast(at);
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
///
/// A window that would end later than time is counted (`limit`) never
/// ends: nothing passes after the item that started it.
pub fn throttle(comptime window: Io.Duration) Throttle(window) {
    return .{};
}

fn Throttle(comptime window: Io.Duration) type {
    const length = span("time.throttle: window", window);
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
                /// When the last item passed. It starts as a time that no
                /// reading is within a window of: one past the limit.
                passed_at: Nanoseconds,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .io = di.get(env, Io), .passed_at = limit + 1 };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    const now = reading(self.io);
                    // The time since, which fits whatever the two are.
                    // The end of the window is not kept: that is a sum,
                    // and it can be later than the limit.
                    if (now -% self.passed_at < length) return .more;
                    self.passed_at = now;
                    return down.push(item);
                }
            };
        }
    };
}
