//! Running several things together under one supervisor.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");

/// The error set of running every member in the tuple type `Members`.
pub fn Errors(comptime Members: type) type {
    var Set: type = Io.Cancelable || Io.ConcurrentError;
    for (di.types(Members)) |Member| Set = Set || @typeInfo(Result(Member)).error_union.error_set;
    return Set;
}

fn Result(comptime Member: type) type {
    return @typeInfo(@TypeOf(Member.run)).@"fn".return_type.?;
}

/// What the members of one run share with the task that supervises them.
/// Make one per run, hand a pointer to any member that may end the group
/// (`done`), then call `run`.
///
/// The first thing that happens is the outcome, and everything after it is
/// discarded:
///
/// - a member returns an error: the run fails with it;
/// - a member calls `done`: the run succeeds;
/// - every member returns: the run succeeds.
///
/// In the first two cases the other members are cancelled. In every case all
/// members have returned before `run` does.
///
/// A member may say how it relates to the others:
///
///     fed_by: usize                               // a field: the index of the member whose output it takes
///     pub const feeds_only_members = true;        // everything it puts out goes to members that name it
///
/// A member that feeds only members works for nothing once all of those
/// have returned. It is then cancelled, and what it returns is discarded:
/// that is not a failure, and the run goes on for the others.
pub const Scope = struct {
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    outcome: Outcome = .running,
    /// Members that have returned.
    returned: usize = 0,
    /// The run is over and not a success. Read without the mutex.
    failed: std.atomic.Value(bool) = .init(false),
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
        returned: bool = false,
        /// It works for nothing: the scope cancels it and discards its result.
        idle: bool = false,
    };

    const Outcome = union(enum) {
        running,
        /// A member said that nothing more is wanted from the group.
        done,
        /// The member with this index was the first to return an error.
        failed: usize,
        /// The supervising task was cancelled.
        canceled,
        /// A member could not be started.
        unlaunched,
    };

    /// Nothing more is wanted from the group: the run ends as a success and
    /// the other members are cancelled. Called by a member, which then returns.
    pub fn done(scope: *Scope, io: Io) void {
        scope.settle(io, .done);
    }

    /// Whether the run has failed, been cancelled or could not start, as far
    /// as the scope has seen. Cheap: a member reads it before an effect that
    /// belongs to a normal end.
    pub fn hasFailed(scope: *const Scope) bool {
        return scope.failed.load(.acquire);
    }

    fn settle(scope: *Scope, io: Io, outcome: Outcome) void {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        if (scope.outcome == .running) scope.set(outcome);
        scope.changed.signal(io);
    }

    fn set(scope: *Scope, outcome: Outcome) void {
        scope.outcome = outcome;
        if (outcome != .done) scope.failed.store(true, .release);
    }

    fn memberReturned(scope: *Scope, io: Io, index: usize, failed: bool) void {
        scope.mutex.lockUncancelable(io);
        defer scope.mutex.unlock(io);
        const member = &scope.members[index];
        member.returned = true;
        scope.returned += 1;
        if (member.fed_by) |feeder| scope.members[feeder].feeding -= 1;
        if (failed and !member.idle) {
            if (scope.outcome == .running) scope.set(.{ .failed = index });
        }
        scope.changed.signal(io);
    }

    /// A member that is still running although everything it puts out goes
    /// to members that have all returned.
    fn idleMember(scope: *const Scope) ?usize {
        for (scope.members, 0..) |member, index| {
            if (member.returned or member.idle) continue;
            if (member.feeds_only_members and member.feeds > 0 and member.feeding == 0) return index;
        }
        return null;
    }

    fn Runner(comptime Task: type) type {
        return struct {
            fn run(task: Task, scope: *Scope, io: Io, index: usize) Result(Task) {
                const result = task.run();
                scope.memberReturned(io, index, if (result) |_| false else |_| true);
                return result;
            }
        };
    }

    /// Runs every member (`member.run() !void`) of the tuple `members`, each
    /// as a task of its own, and returns once all of them have.
    ///
    /// Members are started with `Io.concurrent` and never run on the calling
    /// task, which only waits: it has to stay free to see a failure and
    /// cancel the rest. If a member cannot be started, those already running
    /// are cancelled and the run fails with `error.ConcurrencyUnavailable`.
    ///
    /// Cancelling the calling task cancels every member and returns
    /// `error.Canceled`, whatever else has happened.
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
        inline for (0..n) |i| state[i] = .{
            .fed_by = if (@hasField(types[i], "fed_by")) members[i].fed_by else null,
            .feeds_only_members = @hasDecl(types[i], "feeds_only_members") and types[i].feeds_only_members,
        };
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
                if (io.concurrent(Runner(types[i]).run, .{ members[i], scope, io, i })) |future| {
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
                    // Marked first, so that whatever it returns on being
                    // cancelled is not taken for a failure.
                    state[index].idle = true;
                    scope.mutex.unlock(io);
                    inline for (0..n) |i| {
                        if (i == index) {
                            if (futures[i].cancel(io)) |_| {} else |_| {}
                        }
                    }
                    scope.mutex.lockUncancelable(io);
                    continue;
                }
                scope.changed.wait(io, &scope.mutex) catch scope.set(.canceled);
            }
            break :waiting scope.outcome;
        };

        if (outcome == .running) {
            // Every member returned, and none with an error that counts.
            inline for (0..n) |i| {
                if (!state[i].idle) try futures[i].await(io);
            }
            return;
        }
        inline for (0..n) |i| {
            if (i < started) {
                if (futures[i].cancel(io)) |_| {} else |_| {}
            }
        }
        switch (outcome) {
            .running => unreachable,
            .done => {},
            .failed => |culprit| inline for (0..n) |i| {
                // Already joined: this only reads what the member returned.
                if (culprit == i) return futures[i].cancel(io);
            },
            .canceled => return error.Canceled,
            .unlaunched => return error.ConcurrencyUnavailable,
        }
    }
};
