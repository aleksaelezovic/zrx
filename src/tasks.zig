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
///     pub fn retire(member) void     // nobody may wait on its work again; see below
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
/// be cancelled. When the run is over without every member having returned
/// by itself, everyone is told at once: every member is retired, so that
/// nobody waits on anybody's work again, and all members are asked to cancel
/// together. Then they are joined, and the supervising task looks at its own
/// cancellation once more (see `run`).
///
/// `retire` is therefore called by the member's own task when its work is
/// over, and by the supervising task when the run is: more than once, from
/// two tasks. It must not wait for anything.
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
            fn run(task: Task, scope: *Scope, io: Io, index: usize, result: *Result(Task)) void {
                const worked = task.run();
                if (worked) |_| {} else |_| scope.workFailed(io, index);
                if (@hasDecl(Task, "retire")) task.retire();
                result.* = if (worked) |_| ending: {
                    if (!@hasDecl(Task, "end") or !scope.mayEnd(io)) break :ending {};
                    break :ending task.end();
                } else |_| worked;
                // (A failed `run` is on record already.)
                scope.memberReturned(io, index, if (worked) |_| if (result.*) |_| false else |_| true else |_| false);
            }
        };
    }

    fn sameIo(a: Io, b: Io) bool {
        return a.userdata == b.userdata and a.vtable == b.vtable;
    }

    /// Runs every member of the tuple `members`, each as a task of its own,
    /// and returns once all of them have.
    ///
    /// Members are started with `Io.concurrent` and never run on the calling
    /// task, which only waits: it has to stay free to see a failure and
    /// cancel the rest. A member is started, joined and cancelled on its own
    /// `Io` if it names one, and on `io` otherwise. A member that cannot be
    /// started is an outcome like any other: unless the run already has one
    /// (a member failed, or said the group is done), those already running
    /// are cancelled and the run fails with `error.ConcurrencyUnavailable`.
    ///
    /// If the calling task is asked to cancel before this function has
    /// joined its members, the result is `error.Canceled`, whatever the
    /// members did. A request that arrives while it waits ends the wait and
    /// cancels every member; one that arrives while it joins them (which is
    /// not a cancelation point) is taken in a last look after the joins.
    ///
    /// Members on the same `Io` are asked to cancel together (they share an
    /// `Io.Group`). Members on different `Io`s are asked one `Io` after
    /// another: a group is told by joining it.
    pub fn run(scope: *Scope, io: Io, members: anytype) Errors(@TypeOf(members))!void {
        const types = comptime di.types(@TypeOf(members));
        const n = types.len;
        const Results = comptime blk: {
            var list: [n]type = undefined;
            for (types, 0..) |Task, i| list[i] = Result(Task);
            break :blk @Tuple(&list);
        };

        // Members on the same `Io` share a group: the one of the first of them.
        var ios: [n]Io = undefined;
        var group_of: [n]usize = undefined;
        inline for (0..n) |i| {
            ios[i] = if (@hasDecl(types[i], "io")) members[i].io() else io;
            group_of[i] = i;
            for (0..i) |earlier| {
                if (sameIo(ios[earlier], ios[i])) {
                    group_of[i] = group_of[earlier];
                    break;
                }
            }
        }

        var groups: [n]Io.Group = @splat(.init);
        var results: Results = undefined;
        var started: usize = 0;
        inline for (0..n) |i| {
            if (started == i) {
                if (groups[group_of[i]].concurrent(ios[i], Runner(types[i]).run, .{ members[i], scope, ios[i], i, &results[i] })) |_| {
                    started += 1;
                } else |_| scope.settle(io, .unlaunched);
            }
        }

        // This task was asked to cancel while it waited, or while it joined.
        var interrupted = false;
        const outcome = waiting: {
            scope.mutex.lockUncancelable(io);
            defer scope.mutex.unlock(io);
            while (scope.outcome == .running and scope.returned < n) {
                scope.changed.wait(io, &scope.mutex) catch {
                    interrupted = true;
                    // The members are told through the outcome: none of
                    // them goes on to end.
                    if (scope.outcome == .running) scope.outcome = .canceled;
                };
            }
            break :waiting scope.outcome;
        };

        if (outcome != .running) {
            // The run is over and not every member returned by itself.
            // Nobody is to wait on anybody's work again: a member whose
            // request to cancel gets lost on the way (an `Io` layer may
            // report it as another error) still comes to an end.
            inline for (0..n) |i| {
                if (@hasDecl(types[i], "retire")) members[i].retire();
            }
        }
        for (&groups, 0..) |*group, i| {
            if (group_of[i] != i) continue;
            if (outcome == .running) {
                // Every member has returned; this only gives them back.
                group.await(ios[i]) catch {
                    interrupted = true;
                };
            } else group.cancel(ios[i]);
        }

        // This task's own cancellation comes before whatever the members
        // did: a request that ended the wait, or one that came while joining
        // (which need not be a cancelation point).
        if (interrupted) return error.Canceled;
        try io.checkCancel();
        switch (outcome) {
            // Every member returned, and none failed.
            .running, .done => {},
            .failed => |culprit| inline for (0..n) |i| {
                if (culprit == i) return results[i];
            },
            // Only ever set when the wait was interrupted.
            .canceled => unreachable,
            .unlaunched => return error.ConcurrencyUnavailable,
        }
    }
};
