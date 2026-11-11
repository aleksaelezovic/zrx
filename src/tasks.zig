//! Running several things together, failing fast.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");

/// The error set of running every task in the tuple type `Tasks`.
pub fn Errors(comptime Tasks: type) type {
    var Set: type = Io.Cancelable || Io.ConcurrentError;
    for (di.types(Tasks)) |Task| {
        Set = Set || @typeInfo(@typeInfo(@TypeOf(Task.run)).@"fn".return_type.?).error_union.error_set;
    }
    return Set;
}

/// What the members of one `all` share with whoever supervises them, and how
/// a member says, before it returns, that the whole group is over. The first
/// thing said is the outcome; later ones are ignored.
///
/// `Reported` is the set of errors a member may report with `fail`.
pub fn Watch(comptime Reported: type) type {
    return struct {
        mutex: Io.Mutex = .init,
        changed: Io.Condition = .init,
        outcome: ?Outcome = null,
        /// Members that have returned.
        returned: usize = 0,

        const Self = @This();

        pub const Outcome = union(enum) {
            /// Nothing more is wanted: a success.
            done,
            /// A member reported this failure and may still be running.
            reported: Reported,
            /// A member returned this error.
            failed: anyerror,
        };

        fn settle(watch: *Self, io: Io, outcome: Outcome) void {
            watch.mutex.lockUncancelable(io);
            defer watch.mutex.unlock(io);
            if (watch.outcome == null) watch.outcome = outcome;
            watch.changed.broadcast(io);
        }

        /// The group has failed with `err`, now: the others are cancelled
        /// without waiting for the caller to return.
        pub fn fail(watch: *Self, io: Io, err: Reported) void {
            watch.settle(io, .{ .reported = err });
        }

        /// Nothing more is wanted from the group: the others are cancelled,
        /// and that is a success.
        pub fn satisfy(watch: *Self, io: Io) void {
            watch.settle(io, .done);
        }

        fn memberReturned(watch: *Self, io: Io, result: ?anyerror) void {
            watch.mutex.lockUncancelable(io);
            defer watch.mutex.unlock(io);
            if (result) |err| {
                if (watch.outcome == null) watch.outcome = .{ .failed = err };
            }
            watch.returned += 1;
            watch.changed.broadcast(io);
        }

        fn current(watch: *Self, io: Io) struct { outcome: ?Outcome, returned: usize } {
            watch.mutex.lockUncancelable(io);
            defer watch.mutex.unlock(io);
            return .{ .outcome = watch.outcome, .returned = watch.returned };
        }
    };
}

/// Runs every task (`task.run() !void`) and returns when all have succeeded.
/// The first failure cancels the others, waits for them, and is returned;
/// so does the first `watch.satisfy`, as a success. A failure is acted on when
/// it is reported or returned, whichever comes first: a member that reports
/// with `watch.fail` is not waited for.
///
/// Tasks are started with `Io.concurrent`, never run on the caller's task
/// while others are running: the caller has to stay free to see a failure and
/// cancel the rest. An `Io` that cannot run anything concurrently runs the
/// tasks one after another instead, and does not start one once the outcome
/// is settled. An `Io` that ran some tasks concurrently and then cannot start
/// another fails with `error.ConcurrencyUnavailable`.
pub fn all(io: Io, tasks: anytype, watch: anytype) (Errors(@TypeOf(tasks)) || ReportedBy(@TypeOf(watch)))!void {
    const Tasks = @TypeOf(tasks);
    const n = comptime di.types(Tasks).len;
    const W = @typeInfo(@TypeOf(watch)).pointer.child;
    if (n == 1) return tasks[0].run();

    const Member = struct {
        fn For(comptime Task: type) type {
            return struct {
                fn run(task: Task, shared: *W, member_io: Io) void {
                    var result: ?anyerror = null;
                    task.run() catch |err| {
                        result = err;
                    };
                    shared.memberReturned(member_io, result);
                }
            };
        }
    };
    const resolve = struct {
        fn outcome(settled: W.Outcome) (Errors(Tasks) || ReportedBy(@TypeOf(watch)))!void {
            switch (settled) {
                .done => {},
                .reported => |err| return err,
                .failed => |err| return @as(Errors(Tasks), @errorCast(err)),
            }
        }
    }.outcome;

    var group: Io.Group = .init;
    defer group.cancel(io);
    var started: usize = 0;
    inline for (0..n) |i| {
        // Whatever has already happened decides whether the next task starts.
        const so_far = watch.current(io);
        if (so_far.outcome) |settled| return resolve(settled);

        if (group.concurrent(io, Member.For(@TypeOf(tasks[i])).run, .{ tasks[i], watch, io })) |_| {
            started += 1;
        } else |err| switch (err) {
            error.ConcurrencyUnavailable => {
                // Running it here would block this task. That is only safe
                // when nothing else is running that it would have to watch.
                if (so_far.returned != started) return error.ConcurrencyUnavailable;
                // Its result is settled like any member's: what was reported
                // while it ran comes first.
                var result: ?anyerror = null;
                tasks[i].run() catch |inline_err| {
                    result = inline_err;
                };
                watch.memberReturned(io, result);
                started += 1;
            },
        }
    }

    watch.mutex.lockUncancelable(io);
    defer watch.mutex.unlock(io);
    while (watch.outcome == null and watch.returned < started) try watch.changed.wait(io, &watch.mutex);
    if (watch.outcome) |settled| return resolve(settled);
}

/// The error set members may report through the watch `WatchPointer` points to.
fn ReportedBy(comptime WatchPointer: type) type {
    return @FieldType(@typeInfo(WatchPointer).pointer.child.Outcome, "reported");
}
