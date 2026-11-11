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
        /// supervised tasks: the workers its stages start, and the source.
        ///
        /// - The source is a task so that it can be cancelled. When a worker
        ///   fails, or nothing wants another item, the source is not left to
        ///   find out at its next push, which for an idle source might never
        ///   come. What a source returns after being interrupted is a
        ///   consequence, not a result.
        /// - The first failure of a worker is the result of the run. Once
        ///   there is one, no stage finishes and no join waits: an effect of
        ///   a normal end must not follow a failure.
        /// - `stop` then cancels and joins every worker before anything is
        ///   torn down.
        fn runSupervised(self: *const @This(), outer: anytype) !void {
            var signal: Signal = .{};
            const supervision: Supervision = .{ .signal = &signal };
            const env = di.extend(outer, supervision);
            const Env = @TypeOf(env);
            const Frame = P.Stage(Env, S.Item);
            const Feed = struct {
                fn run(source: *const S, feed_env: Env, entry: Entry(Frame, S.Item), wake: *Signal, io: Io) !void {
                    defer {
                        wake.mutex.lockUncancelable(io);
                        wake.source_ended = true;
                        wake.changed.broadcast(io);
                        wake.mutex.unlock(io);
                    }
                    return source.run(feed_env, entry);
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
                    if (wake.io) |io| {
                        var source = try io.concurrent(Feed.run, .{ &body.program.source, body.env, entry, wake, io });
                        const ended_by_itself = sourceOrSignal(wake, io) catch |err| {
                            // This task is being cancelled: so is the source.
                            source.cancel(io) catch {};
                            return err;
                        };
                        const outcome = source.cancel(io);
                        if (ended_by_itself) try outcome else outcome catch {};
                    } else {
                        try body.program.source.run(body.env, entry);
                    }

                    const Failure = @typeInfo(@TypeOf(Frame.at.finish(refs, Closed{}, body.supervision))).error_union.error_set;
                    if (wake.failure) |first| return recast(Failure, first);
                    Frame.at.finish(refs, Closed{}, body.supervision) catch |err| {
                        // Whatever cut the end short, the failure that caused it is the result.
                        if (firstFailure(wake)) |first| return recast(Failure, first);
                        return err;
                    };
                    try Frame.at.flush(refs);
                }

                /// Waits until the source has ended or the run needs it to:
                /// a worker failed, or nothing wants another item. Returns
                /// whether the source ended by itself.
                fn sourceOrSignal(wake: *Signal, io: Io) Io.Cancelable!bool {
                    wake.mutex.lockUncancelable(io);
                    defer wake.mutex.unlock(io);
                    while (!wake.source_ended and wake.failure == null and !wake.satisfied) {
                        try wake.changed.wait(io, &wake.mutex);
                    }
                    return wake.source_ended;
                }

                /// Read after workers may still be running, so under the lock.
                fn firstFailure(wake: *Signal) ?anyerror {
                    const io = wake.io orelse return wake.failure;
                    wake.mutex.lockUncancelable(io);
                    defer wake.mutex.unlock(io);
                    return wake.failure;
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env, .supervision = supervision });
        }
    };
}

/// An error a worker recorded, as a member of the error set `E` it came from.
fn recast(comptime E: type, err: anyerror) E {
    const names = comptime @typeInfo(E).error_set.error_names;
    if (comptime names == null) return err; // anyerror
    if (comptime names.?.len == 0) unreachable;
    return @errorCast(err);
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
            return tasks.all(di.get(env, Io), group, null);
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
