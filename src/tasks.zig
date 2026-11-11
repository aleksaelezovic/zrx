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

/// Runs every task (`task.run() !void`) and returns when all have succeeded.
/// The first failure cancels the others, waits for them, and is returned.
/// When `stop` is given and becomes true, the tasks still running are
/// cancelled and waited for, and that is a success.
///
/// Tasks are started with `Io.concurrent`, never run on the caller's task
/// while others are running: the caller has to stay free to see a failure and
/// cancel the rest. An `Io` that cannot run anything concurrently runs the
/// tasks one after another instead, and does not start one after an earlier
/// one failed or `stop` was set. An `Io` that ran some tasks concurrently and
/// then cannot start another fails with `error.ConcurrencyUnavailable`.
pub fn all(io: Io, tasks: anytype, stop: ?*const std.atomic.Value(bool)) Errors(@TypeOf(tasks))!void {
    const Tasks = @TypeOf(tasks);
    const n = comptime di.types(Tasks).len;
    if (n == 1) return tasks[0].run();

    const Outcome = union(enum) { finished: ?anyerror };
    const Runner = struct {
        fn For(comptime Task: type) type {
            return struct {
                fn run(task: Task) ?anyerror {
                    task.run() catch |err| return err;
                    return null;
                }
            };
        }
    };

    var results: [n]Outcome = undefined;
    var select: Io.Select(Outcome) = .init(io, &results);
    defer select.cancelDiscard();
    var started: usize = 0;
    var seen: usize = 0;
    inline for (0..n) |i| {
        // Whatever has already finished decides whether the next task starts.
        var ready: [n]Outcome = undefined;
        const count = try select.awaitMany(&ready, 0);
        for (ready[0..count]) |outcome| {
            if (outcome.finished) |err| return @as(Errors(Tasks), @errorCast(err));
        }
        seen += count;
        if (stop) |flag| if (flag.load(.acquire)) return;

        if (select.concurrent(.finished, Runner.For(@TypeOf(tasks[i])).run, .{tasks[i]})) |_| {
            started += 1;
        } else |err| switch (err) {
            error.ConcurrencyUnavailable => {
                // Running it here would block this task. That is only safe
                // when nothing else is running that it would have to watch.
                if (seen != started) return error.ConcurrencyUnavailable;
                try tasks[i].run();
            },
        }
    }
    while (seen < started) : (seen += 1) {
        const outcome = try select.await();
        if (outcome.finished) |err| return @as(Errors(Tasks), @errorCast(err));
        if (stop) |flag| if (flag.load(.acquire)) return;
    }
}
