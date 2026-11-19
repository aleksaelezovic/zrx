//! Helpers for testing programs built with zrx. Needs an operating system:
//! `root.zig` refers to this file lazily, so the core compiles without one.
const std = @import("std");
const Io = std.Io;

/// A `std.Io` whose `.awake` clock stands still until the test moves it.
/// `batchWithin` and `debounce` take time from the program's `Io`, so a
/// program run with `clock.io()` reaches a deadline when the test says so.
///
///     var clock: zrx.testing.Clock = .init(std.testing.io);
///     var run = try io.concurrent(work, .{ clock.io(), ... });
///     try clock.waitingAt(.fromMilliseconds(200));
///     clock.advanceTo(.fromMilliseconds(200));
///
/// Time is a duration since `init`. Only reads of `.awake` and timed futex
/// waits on `.awake` (`Condition.waitTimeout`, `Event.waitTimeout`) use it.
/// Everything else is the wrapped `Io`: untimed waits, tasks, cancellation,
/// files, the other clocks, and `sleep`, which sleeps for real.
///
/// A timed wait is woken through this `Io` only. Whoever signals a condition
/// or sets an event that a task waits on with a timeout uses `clock.io()`
/// too. The stages of a program run with `clock.io()` do.
///
/// The clock is a value the test owns. It must stay where it is while an
/// `Io` made from it is in use, and it must outlive every task given one.
pub const Clock = struct {
    inner: Io,
    /// Nanoseconds since `init`. Read without the mutex by `now`.
    time: std.atomic.Value(i64),
    mutex: Io.Mutex,
    /// Set whenever a timed wait is registered; `waitingAt` waits on it.
    changed: Io.Event,
    waiters: ?*Waiter,

    const Waiter = struct {
        ptr: *const u32,
        deadline: i96,
        ready: Io.Event = .unset,
        next: ?*Waiter,
    };

    /// A clock at zero over `inner`, which does everything but tell the time.
    pub fn init(inner: Io) Clock {
        return .{ .inner = inner, .time = .init(0), .mutex = .init, .changed = .unset, .waiters = null };
    }

    /// The `Io` to pass to `run`. It points at `clock`.
    pub fn io(clock: *Clock) Io {
        return .{ .userdata = clock, .vtable = &vtable };
    }

    /// Sets the time to `since_start`, which must not be earlier than it is
    /// now, and wakes the timed waits whose deadline has come. A wait that
    /// is not due stays asleep: `Io.Event.waitTimeout` takes any wake that
    /// did not set the event for its timeout.
    pub fn advanceTo(clock: *Clock, since_start: Io.Duration) void {
        const inner = clock.inner;
        clock.mutex.lockUncancelable(inner);
        defer clock.mutex.unlock(inner);
        const to: i64 = @intCast(since_start.nanoseconds);
        std.debug.assert(to >= clock.time.load(.seq_cst));
        clock.time.store(to, .seq_cst);
        var it = clock.waiters;
        while (it) |waiter| : (it = waiter.next) {
            if (waiter.deadline <= to) waiter.ready.set(inner);
        }
    }

    /// Returns once some task is in a timed wait whose deadline is
    /// `since_start`: the event a test waits for before it moves the clock
    /// or asserts that nothing was emitted. One task waits here at a time.
    pub fn waitingAt(clock: *Clock, since_start: Io.Duration) Io.Cancelable!void {
        const inner = clock.inner;
        while (true) {
            clock.changed.reset();
            clock.mutex.lockUncancelable(inner);
            var it = clock.waiters;
            while (it) |waiter| : (it = waiter.next) {
                if (waiter.deadline == since_start.nanoseconds and !waiter.ready.isSet()) {
                    clock.mutex.unlock(inner);
                    return;
                }
            }
            clock.mutex.unlock(inner);
            try clock.changed.wait(inner);
        }
    }

    fn from(userdata: ?*anyopaque) *Clock {
        return @ptrCast(@alignCast(userdata));
    }

    fn now(userdata: ?*anyopaque, which: Io.Clock) Io.Timestamp {
        const clock = from(userdata);
        if (which == .awake) return .{ .nanoseconds = clock.time.load(.seq_cst) };
        return clock.inner.vtable.now(clock.inner.userdata, which);
    }

    /// A waiter registers before it checks the futex value, so a concurrent
    /// wake cannot be lost. The wait itself is an untimed one on the wrapped
    /// `Io`, which is also where a request to cancel arrives.
    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const clock = from(userdata);
        const inner = clock.inner;
        const awake = switch (timeout) {
            .none => false,
            .duration => |duration| duration.clock == .awake,
            .deadline => |deadline| deadline.clock == .awake,
        };
        if (!awake) return inner.vtable.futexWait(inner.userdata, ptr, expected, timeout);

        clock.mutex.lockUncancelable(inner);
        const time = clock.time.load(.seq_cst);
        const deadline: i96 = switch (timeout) {
            .none => unreachable,
            .duration => |duration| time + duration.raw.nanoseconds,
            .deadline => |at| at.raw.nanoseconds,
        };
        if (@atomicLoad(u32, ptr, .acquire) != expected or time >= deadline) {
            clock.mutex.unlock(inner);
            return;
        }
        var waiter: Waiter = .{ .ptr = ptr, .deadline = deadline, .next = clock.waiters };
        clock.waiters = &waiter;
        clock.changed.set(inner);
        clock.mutex.unlock(inner);
        defer {
            clock.mutex.lockUncancelable(inner);
            defer clock.mutex.unlock(inner);
            var link = &clock.waiters;
            while (link.*.? != &waiter) link = &link.*.?.next;
            link.* = waiter.next;
        }
        try waiter.ready.wait(inner);
    }

    fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
        const clock = from(userdata);
        const inner = clock.inner;
        clock.mutex.lockUncancelable(inner);
        var it = clock.waiters;
        while (it) |waiter| : (it = waiter.next) {
            if (waiter.ptr == ptr) waiter.ready.set(inner);
        }
        clock.mutex.unlock(inner);
        inner.vtable.futexWake(inner.userdata, ptr, max_waiters);
    }

    /// Every entry hands its arguments to the wrapped `Io`, except the three
    /// above. The entries are generated because `userdata` is the clock, not
    /// what the wrapped functions expect: that is the price of an instance.
    const vtable: Io.VTable = table: {
        var result: Io.VTable = undefined;
        for (@typeInfo(Io.VTable).@"struct".field_names) |name| @field(result, name) = Forward(name).call;
        result.now = now;
        result.futexWait = futexWait;
        result.futexWake = futexWake;
        break :table result;
    };

    fn Forward(comptime name: []const u8) type {
        const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
        const P = info.param_types;
        const R = info.return_type.?;
        if (P[0].? != ?*anyopaque) @compileError("zrx.testing.Clock: `std.Io.VTable." ++ name ++ "` does not take userdata first");
        const to = struct {
            fn inner(userdata: ?*anyopaque, args: anytype) R {
                const wrapped = from(userdata).inner;
                return @call(.auto, @field(wrapped.vtable, name), .{wrapped.userdata} ++ args);
            }
        }.inner;
        return switch (P.len) {
            1 => struct {
                fn call(u: ?*anyopaque) R {
                    return to(u, .{});
                }
            },
            2 => struct {
                fn call(u: ?*anyopaque, a: P[1].?) R {
                    return to(u, .{a});
                }
            },
            3 => struct {
                fn call(u: ?*anyopaque, a: P[1].?, b: P[2].?) R {
                    return to(u, .{ a, b });
                }
            },
            4 => struct {
                fn call(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?) R {
                    return to(u, .{ a, b, c });
                }
            },
            5 => struct {
                fn call(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?) R {
                    return to(u, .{ a, b, c, d });
                }
            },
            6 => struct {
                fn call(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?) R {
                    return to(u, .{ a, b, c, d, e });
                }
            },
            else => @compileError("zrx.testing.Clock: `std.Io.VTable." ++ name ++ "` takes more arguments than are forwarded"),
        };
    }
};
