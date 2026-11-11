//! Programs: a source bound to a terminated pipe, run with its dependencies.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const tasks = @import("tasks.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;
const Supervision = core.Supervision;
const Signal = core.Supervision.Signal;

pub fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_source");
}

pub fn isProgram(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_program");
}

/// One source feeding one pipe. The pipe must terminate.
/// Nothing happens until `run`.
pub fn program(source: anytype, pipeline: anytype) Program(@TypeOf(source), @TypeOf(pipeline)) {
    return .{ .source = source, .pipe = pipeline };
}

pub fn Program(comptime S: type, comptime P: type) type {
    @setEvalBranchQuota(di.quota);
    if (!isSource(S)) @compileError("program: the first argument must be a source such as fromSlice(...), got `" ++ @typeName(S) ++ "`");
    core.expectPipe("program", P);
    return struct {
        source: S,
        pipe: P,

        pub const zrx_program = {};

        /// Runs the program to completion with `deps`, a tuple of dependency
        /// values keyed by their types, e.g. `.{ io, logger }`.
        pub fn run(self: *const @This(), deps: anytype) !void {
            const env = di.normalize(deps);
            const Env = @TypeOf(env);
            const Out = P.Out(Env, S.Item);
            if (Out != End) @compileError(
                "program: the pipe must terminate, but it still emits `" ++ @typeName(Out) ++
                    "`; end it with subscribe(...), drain() or another terminal operator",
            );

            if (comptime !P.Stage(Env, S.Item).has_boundary) return self.runHere(env);
            return self.runSupervised(env);
        }

        /// The whole program is one loop on the caller's task.
        fn runHere(self: *const @This(), env: anytype) !void {
            const Frame = P.Stage(@TypeOf(env), S.Item);
            const Body = struct {
                program: *const Program(S, P),
                env: @TypeOf(env),

                pub fn call(body: @This(), refs: Frame.Refs) !void {
                    try Frame.at.init(refs, &body.program.pipe.ops, body.env);
                    defer {
                        Frame.at.stop(refs);
                        Frame.at.deinit(refs);
                    }
                    try Frame.at.start(refs, Closed{});
                    try body.program.source.run(body.env, Entry(Frame, S.Item){ .refs = refs });
                    try Frame.at.finish(refs, Closed{}, {});
                    try Frame.at.flush(refs);
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env });
        }

        /// The pipe crosses a task boundary, so the run is a group of
        /// supervised tasks: the workers its stages start, one that feeds the
        /// pipe from the source, and then one that finishes and flushes it.
        /// The caller only waits and cancels, so it is always free to act:
        ///
        /// - Feeding is a task so that the source can be cancelled. When a
        ///   worker fails, or nothing wants another item, the source is not
        ///   left to find out at its next push, which for an idle source
        ///   might never come. What a source returns after being interrupted
        ///   is a consequence, not a result.
        /// - Ending is a task for the same reason: a final value's handler
        ///   can block too, and a failure elsewhere must still end the run.
        /// - The first failure of a worker is the result of the run. It is
        ///   returned by the stage that failed (`failureOf`), not carried
        ///   here as a value, so the run's error set stays inferred.
        /// - `stop` then cancels and joins every worker before anything is
        ///   torn down.
        fn runSupervised(self: *const @This(), outer: anytype) !void {
            var signal: Signal = .{};
            const supervision: Supervision = .{ .signal = &signal };
            const env = di.extend(outer, supervision);
            const Env = @TypeOf(env);
            const Frame = P.Stage(Env, S.Item);
            const Phase = enum { feeding, ending };
            const Tasks = struct {
                fn ended(wake: *Signal, io: Io, comptime phase: Phase) void {
                    wake.mutex.lockUncancelable(io);
                    defer wake.mutex.unlock(io);
                    switch (phase) {
                        .feeding => wake.feeding_ended = true,
                        .ending => wake.ending_ended = true,
                    }
                    wake.changed.broadcast(io);
                }

                fn feed(source: *const S, feed_env: Env, entry: Entry(Frame, S.Item), wake: *Signal, io: Io) !void {
                    defer ended(wake, io, .feeding);
                    return source.run(feed_env, entry);
                }

                fn end(refs: Frame.Refs, guard: Supervision, wake: *Signal, io: Io) !void {
                    defer ended(wake, io, .ending);
                    try Frame.at.finish(refs, Closed{}, guard);
                    try Frame.at.flush(refs);
                }

                /// Waits until the task of `phase` has returned or the run
                /// needs it to: a worker failed, or (while feeding) nothing
                /// wants another item. Returns whether it returned by itself.
                fn wait(wake: *Signal, io: Io, comptime phase: Phase) Io.Cancelable!bool {
                    wake.mutex.lockUncancelable(io);
                    defer wake.mutex.unlock(io);
                    while (true) {
                        const returned = switch (phase) {
                            .feeding => wake.feeding_ended,
                            .ending => wake.ending_ended,
                        };
                        if (returned) return true;
                        if (wake.failed_stage != null) return false;
                        if (phase == .feeding and wake.satisfied) return false;
                        try wake.changed.wait(io, &wake.mutex);
                    }
                }
            };
            const Body = struct {
                program: *const Program(S, P),
                env: Env,
                supervision: Supervision,

                pub fn call(body: @This(), refs: Frame.Refs) !void {
                    const wake = body.supervision.signal;
                    try Frame.at.init(refs, &body.program.pipe.ops, body.env);
                    defer {
                        Frame.at.stop(refs);
                        Frame.at.deinit(refs);
                    }
                    try Frame.at.start(refs, Closed{});

                    // Every worker that started gave its `Io`. With none,
                    // there is nobody to supervise.
                    const entry: Entry(Frame, S.Item) = .{ .refs = refs };
                    const io = wake.io orelse {
                        try body.program.source.run(body.env, entry);
                        try Frame.at.finish(refs, Closed{}, body.supervision);
                        return Frame.at.flush(refs);
                    };

                    var feeding = try io.concurrent(Tasks.feed, .{ &body.program.source, body.env, entry, wake, io });
                    const fed_by_itself = Tasks.wait(wake, io, .feeding) catch |err| {
                        // This task is being cancelled: so is the source.
                        feeding.cancel(io) catch {};
                        return err;
                    };
                    const fed = feeding.cancel(io);
                    if (fed_by_itself) try fed else fed catch {};
                    try body.failureIfAny(refs, io);

                    var ending = try io.concurrent(Tasks.end, .{ refs, body.supervision, wake, io });
                    _ = Tasks.wait(wake, io, .ending) catch |err| {
                        ending.cancel(io) catch {};
                        return err;
                    };
                    const finished = ending.cancel(io);
                    // Whatever cut the end short, the failure that caused it is the result.
                    try body.failureIfAny(refs, io);
                    try finished;
                }

                /// Returns the failure of the first worker that failed, as
                /// that worker's stage returns it.
                fn failureIfAny(body: @This(), refs: Frame.Refs, io: Io) !void {
                    const who = body.supervision.failedStage(io) orelse return;
                    try Frame.at.failureOf(refs, Closed{}, who);
                    // A stage reported a failure and then returned none. The
                    // run still must not look like a success.
                    return error.Canceled;
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env, .supervision = supervision });
        }
    };
}

/// The `down` a source pushes into.
fn Entry(comptime Frame: type, comptime Item: type) type {
    return struct {
        refs: Frame.Refs,

        pub fn push(entry: @This(), item: Item) !Flow {
            return Frame.at.push(entry.refs, item, Closed{});
        }
    };
}

/// Several programs (or systems) run together with the same dependencies.
/// Returns when all have completed; the first failure cancels the rest.
/// With more than one member, `std.Io` must be among the dependencies.
pub fn system(programs: anytype) System(Programs(@TypeOf(programs))) {
    var out: Programs(@TypeOf(programs)) = undefined;
    inline for (0..programs.len) |i| out[i] = programs[i];
    return .{ .programs = out };
}

fn Programs(comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(Given)) @compileError("system: expected a tuple of programs `.{ a, b }`, got `" ++ @typeName(Given) ++ "`");
    const list = di.types(Given);
    if (list.len == 0) @compileError("system: needs at least one program");
    for (list, 0..) |P, i| if (!isProgram(P)) @compileError(std.fmt.comptimePrint(
        "system: element {d} is not a program (got `{s}`); build one with program(source, pipe(...))",
        .{ i, @typeName(P) },
    ));
    return @Tuple(list);
}

pub fn System(comptime Ps: type) type {
    const members = di.types(Ps);
    return struct {
        programs: Ps,

        pub const zrx_program = {};

        pub fn run(self: *const @This(), deps: anytype) !void {
            const env = di.normalize(deps);
            const Env = @TypeOf(env);
            if (members.len == 1) return self.programs[0].run(env);
            if (comptime !di.has(Env, Io)) @compileError("system: needs `std.Io` to run programs together; pass `io` to `run(.{ io, ... })`");

            const list = comptime blk: {
                var types: [members.len]type = undefined;
                for (members, 0..) |P, i| types[i] = Member(P, Env);
                break :blk types;
            };
            var group: @Tuple(&list) = undefined;
            inline for (0..members.len) |i| group[i] = .{ .program = &self.programs[i], .env = env };
            var watch: tasks.Watch(error{}) = .{};
            return tasks.all(di.get(env, Io), group, &watch);
        }
    };
}

fn Member(comptime P: type, comptime Env: type) type {
    return struct {
        program: *const P,
        env: Env,

        pub fn run(self: @This()) !void {
            return self.program.run(self.env);
        }
    };
}
