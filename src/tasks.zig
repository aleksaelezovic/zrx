//! Running several things together under one supervisor.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");

/// The error set of running every member in the tuple type `Members`.
pub fn Errors(comptime Members: type) type {
    var Set: type = Io.Cancelable || Io.ConcurrentError;
    for (di.types(Members)) |Task| Set = Set || @typeInfo(Result(Task)).error_union.error_set;
    return Set;
}

fn errorsOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}

/// What a member's task returns: whatever its `run` or its `end` failed with.
fn Result(comptime Task: type) type {
    return (errorsOf(Task.run) || if (@hasDecl(Task, "end")) errorsOf(Task.end) else error{})!void;
}

/// What the members of one run share with the task that supervises them.
/// Make one per run, hand a pointer to any member that may end the group
/// (`done`), then call `run`.
///
/// The first thing that happens is the outcome:
///
/// - a member fails: the run fails with that error;
/// - a member calls `done`: the run succeeds;
/// - every member returns: the run succeeds.
///
/// In the first two cases the other members are cancelled. In every case all
/// members have returned before `run` does.
///
/// ## A member
///
/// A member is a value with `run`, and optionally more:
///
///     pub fn run(member) !void       // its work
///     pub fn retire(member) void     // its work is over, however it ended: nobody may wait on it again
///     pub fn end(member) !void       // what follows its work when that ended well
///     pub fn io(member) Io           // the `Io` its task runs on, instead of the scope's
///
/// Every member's task takes the same steps, in one place (`Runner`):
///
/// 1. `run`.
/// 2. Under the scope's mutex: if `run` failed, the run has failed, and that
///    is on record.
/// 3. `retire`: from here on nobody waits on this member's work. It comes
///    after step 2, so whoever is let go by it finds a failure on record.
/// 4. Under the mutex again, as the last thing before it: whether to end.
///    Not if the run is over.
/// 5. `end`. A failure of `end` fails the run like any other.
///
/// The supervising task waits in one place, for a change, and that wait can
/// be cancelled. Then it joins every member, and before it returns it looks
/// at its own cancellation once more (see `run`).
pub const Scope = struct {
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    outcome: Outcome = .running,
    /// Members that have returned.
    returned: usize = 0,

    const Outcome = union(enum) {
        running,
        /// A member said that nothing more is wanted from the group.
        done,
        /// The member with this index was the first to fail.
        failed: usize,
        /// The supervising task was cancelled while it waited.
        canceled,
        /// A member could not be started.
        unlaunched,
    };

    /// Nothing more is wanted from the group: the run ends as a success and
    /// the other members are cancelled. Called by a member, which then returns.
    pub fn done(scope: *Scope, io: Io) void {
        scope.settle(io, .done);
    }

    fn settle(scope: *Scope, io: Io, outcome: Outcome) void {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        if (scope.outcome == .running) scope.outcome = outcome;
        scope.changed.signal(io);
    }

    /// A member's work failed: on record here, before the member retires.
    fn workFailed(scope: *Scope, io: Io, index: usize) void {
        scope.settle(io, .{ .failed = index });
    }

    /// Whether a member that has retired goes on to `end`: asked as the last
    /// thing before it would.
    fn mayEnd(scope: *Scope, io: Io) bool {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        return scope.outcome == .running;
    }

    fn memberReturned(scope: *Scope, io: Io, index: usize, failed: bool) void {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        scope.returned += 1;
        if (failed and scope.outcome == .running) scope.outcome = .{ .failed = index };
        scope.changed.signal(io);
    }

    /// The task of one member: the steps every member takes (see `Scope`).
    fn Runner(comptime Task: type) type {
        return struct {
            fn run(task: Task, scope: *Scope, io: Io, index: usize) Result(Task) {
                const worked = task.run();
                if (worked) |_| {} else |_| scope.workFailed(io, index);
                if (@hasDecl(Task, "retire")) task.retire();
                const ended: Result(Task) = if (worked) |_| ending: {
                    if (!@hasDecl(Task, "end") or !scope.mayEnd(io)) break :ending {};
                    break :ending task.end();
                } else |_| worked;
                // (A failed `run` is on record already.)
                scope.memberReturned(io, index, if (worked) |_| if (ended) |_| false else |_| true else |_| false);
                return ended;
            }
        };
    }

    /// Runs every member of the tuple `members`, each as a task of its own,
    /// and returns once all of them have.
    ///
    /// Members are started with `Io.concurrent` and never run on the calling
    /// task, which only waits: it has to stay free to see a failure and
    /// cancel the rest. A member is started, joined and cancelled on its own
    /// `Io` if it names one, and on `io` otherwise. If a member cannot be
    /// started, those already running are cancelled and the run fails with
    /// `error.ConcurrencyUnavailable`.
    ///
    /// If the calling task has been asked to cancel by the time `run` would
    /// return, `run` returns `error.Canceled`, whatever the members did. A
    /// request that arrives while it waits ends the wait and cancels every
    /// member; one that arrives while it joins them is seen in a last look
    /// before it returns.
    ///
    /// Members are cancelled one after another, in order: a task is sent a
    /// cancel request by joining it. One that is slow to notice delays the
    /// request to those after it.
    pub fn run(scope: *Scope, io: Io, members: anytype) Errors(@TypeOf(members))!void {
        const types = comptime di.types(@TypeOf(members));
        const n = types.len;
        const Futures = comptime blk: {
            var list: [n]type = undefined;
            for (types, 0..) |Task, i| list[i] = Io.Future(Result(Task));
            break :blk @Tuple(&list);
        };

        var ios: [n]Io = undefined;
        inline for (0..n) |i| ios[i] = if (@hasDecl(types[i], "io")) members[i].io() else io;

        var futures: Futures = undefined;
        var started: usize = 0;
        inline for (0..n) |i| {
            if (started == i) {
                if (ios[i].concurrent(Runner(types[i]).run, .{ members[i], scope, ios[i], i })) |future| {
                    futures[i] = future;
                    started += 1;
                } else |_| scope.settle(io, .unlaunched);
            }
        }

        const outcome = waiting: {
            scope.mutex.lockUncancelable(io);
            defer scope.mutex.unlock(io);
            while (scope.outcome == .running and scope.returned < n) {
                scope.changed.wait(io, &scope.mutex) catch {
                    scope.outcome = .canceled;
                };
            }
            break :waiting scope.outcome;
        };

        // Join everyone: those still running are cancelled unless every
        // member has returned by itself.
        inline for (0..n) |i| {
            if (i < started) {
                const result = if (outcome == .running) futures[i].await(ios[i]) else futures[i].cancel(ios[i]);
                if (result) |_| {} else |_| {}
            }
        }
        // Joining is not a cancelation point. A request that came for this
        // task meanwhile is taken here, as the last thing before returning.
        try io.checkCancel();
        switch (outcome) {
            // Every member returned, and none failed.
            .running, .done => {},
            .failed => |culprit| inline for (0..n) |i| {
                // Already joined: this only reads what the member returned.
                if (culprit == i) return futures[i].cancel(ios[i]);
            },
            .canceled => return error.Canceled,
            .unlaunched => return error.ConcurrencyUnavailable,
        }
    }
};
