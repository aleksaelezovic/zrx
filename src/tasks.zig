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
///     fed_by: usize                  // a field: the index of the member whose output it takes
///     pub const feeds_only_members   // everything it puts out goes to members that name it
///
/// Every member's task takes the same steps, in one place (`Runner`), so
/// that what the end of a member's work means is decided once and before
/// anybody else can see that it ended:
///
/// 1. `run`.
/// 2. Under the scope's mutex: if `run` failed, the run has failed, and that
///    is on record. If the run is over for another reason, the member stops
///    here.
/// 3. `retire`: from here on nobody waits on this member's work. It comes
///    after step 2, so whoever is let go by it finds a failure on record.
/// 4. `end`, unless the member stopped in step 2. A failure of `end` fails
///    the run like any other.
///
/// ## Working for nothing
///
/// A member that feeds only members works for nothing once all of those have
/// returned. If it is still at work (`run`), the scope cancels it, and that
/// is then as good as its work having ended well: whatever `run` returns is
/// dropped, and `retire` and `end` follow as usual. Being cancelled this way
/// is only a faster way of finding out what the member would have found out
/// from its own output: nothing may depend on which of the two it was. A
/// member that is already ending is left to end.
pub const Scope = struct {
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    outcome: Outcome = .running,
    /// Members that have returned.
    returned: usize = 0,
    /// One per member, for the length of `run`.
    members: []Member = &.{},

    const Member = struct {
        /// The member whose output this one takes.
        fed_by: ?usize,
        /// Everything it puts out goes to the members it feeds.
        feeds_only_members: bool,
        /// How many members it feeds, and how many of those are still running.
        feeds: usize = 0,
        feeding: usize = 0,
        phase: enum { working, ending, returned } = .working,
        /// It was at work for nothing and the scope is cancelling it.
        retired: bool = false,
    };

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

    /// What a member does once its work is over.
    const Next = enum {
        /// It failed, and that is on record: return the failure.
        fail,
        /// The run is over: return.
        stop,
        /// Go on to `end`.
        end,
        /// Go on to `end`; the scope has cancelled this member, or is about to.
        end_retired,
    };

    fn workEnded(scope: *Scope, io: Io, index: usize, failed: bool) Next {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        const member = &scope.members[index];
        if (failed and !member.retired) {
            if (scope.outcome == .running) scope.outcome = .{ .failed = index };
            scope.changed.signal(io);
            return .fail;
        }
        if (scope.outcome != .running) return .stop;
        // From here on the scope does not cancel it for working for nothing.
        member.phase = .ending;
        return if (member.retired) .end_retired else .end;
    }

    fn memberReturned(scope: *Scope, io: Io, index: usize, failed: bool) void {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        const member = &scope.members[index];
        member.phase = .returned;
        scope.returned += 1;
        if (member.fed_by) |feeder| scope.members[feeder].feeding -= 1;
        if (failed and scope.outcome == .running) scope.outcome = .{ .failed = index };
        scope.changed.signal(io);
    }

    /// A member that is still at work although everything it puts out goes
    /// to members that have all returned.
    fn idleMember(scope: *const Scope) ?usize {
        for (scope.members, 0..) |member, index| {
            if (member.phase != .working or member.retired) continue;
            if (member.feeds_only_members and member.feeds > 0 and member.feeding == 0) return index;
        }
        return null;
    }

    /// The task of one member: the steps every member takes (see `Scope`).
    fn Runner(comptime Task: type) type {
        return struct {
            fn run(task: Task, scope: *Scope, io: Io, index: usize) Result(Task) {
                const worked = task.run();
                const next = scope.workEnded(io, index, if (worked) |_| false else |_| true);
                if (@hasDecl(Task, "retire")) task.retire();
                const result: Result(Task) = switch (next) {
                    .fail => worked,
                    .stop => {},
                    .end, .end_retired => ending: {
                        if (!@hasDecl(Task, "end")) break :ending {};
                        // The request that retires this member may not have
                        // reached it yet. It must not land in `end`, where
                        // it would look like a failure; and it is the only
                        // request this task will ever be sent.
                        var before: Io.CancelProtection = .unblocked;
                        if (next == .end_retired) before = io.swapCancelProtection(.blocked);
                        defer if (next == .end_retired) {
                            _ = io.swapCancelProtection(before);
                        };
                        break :ending task.end();
                    },
                };
                scope.memberReturned(io, index, next != .fail and if (result) |_| false else |_| true);
                return result;
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
    /// Cancelling the calling task while it waits for an outcome cancels
    /// every member and returns `error.Canceled`. Once there is an outcome
    /// the calling task only joins, which is not a cancelation point: a
    /// request that arrives then stays pending for the caller, and `run`
    /// returns the outcome it had.
    ///
    /// Members are cancelled one after another, in order: a task is sent a
    /// cancel request by joining it. One that is slow to notice delays the
    /// request to those after it, and, when it is cancelled for working for
    /// nothing, anything else the calling task would react to.
    pub fn run(scope: *Scope, io: Io, members: anytype) Errors(@TypeOf(members))!void {
        const types = comptime di.types(@TypeOf(members));
        const n = types.len;
        const Futures = comptime blk: {
            var list: [n]type = undefined;
            for (types, 0..) |Task, i| list[i] = Io.Future(Result(Task));
            break :blk @Tuple(&list);
        };

        var state: [n]Member = undefined;
        var ios: [n]Io = undefined;
        inline for (0..n) |i| {
            state[i] = .{
                .fed_by = if (@hasField(types[i], "fed_by")) members[i].fed_by else null,
                .feeds_only_members = @hasDecl(types[i], "feeds_only_members") and types[i].feeds_only_members,
            };
            ios[i] = if (@hasDecl(types[i], "io")) members[i].io() else io;
        }
        for (state) |member| {
            if (member.fed_by) |feeder| {
                state[feeder].feeds += 1;
                state[feeder].feeding += 1;
            }
        }
        scope.members = &state;
        defer scope.members = &.{};

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
                if (scope.idleMember()) |index| {
                    // Marked first, under the mutex: the member then knows
                    // that this request is not a failure.
                    state[index].retired = true;
                    scope.mutex.unlock(io);
                    inline for (0..n) |i| {
                        if (i == index) {
                            if (futures[i].cancel(ios[i])) |_| {} else |_| {}
                        }
                    }
                    scope.mutex.lockUncancelable(io);
                    continue;
                }
                scope.changed.wait(io, &scope.mutex) catch {
                    scope.outcome = .canceled;
                };
            }
            break :waiting scope.outcome;
        };

        if (outcome == .running) {
            // Every member returned, and none failed.
            inline for (0..n) |i| try futures[i].await(ios[i]);
            return;
        }
        inline for (0..n) |i| {
            if (i < started) {
                if (futures[i].cancel(ios[i])) |_| {} else |_| {}
            }
        }
        switch (outcome) {
            .running => unreachable,
            .done => {},
            .failed => |culprit| inline for (0..n) |i| {
                // Already joined: this only reads what the member returned.
                if (culprit == i) return futures[i].cancel(ios[i]);
            },
            .canceled => return error.Canceled,
            .unlaunched => return error.ConcurrencyUnavailable,
        }
    }
};
