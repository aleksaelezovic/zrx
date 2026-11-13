//! Programs: a source bound to a terminated pipe, run with its dependencies.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const tasks = @import("tasks.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;

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

            const Frame = P.Stage(Env, S.Item);
            const Body = struct {
                program: *const Program(S, P),
                env: Env,

                pub fn call(body: @This(), refs: Frame.Refs) !void {
                    try Frame.at.init(refs, &body.program.pipe.ops, body.env);
                    defer Frame.at.deinit(refs);
                    if (comptime !Frame.has_boundary) {
                        // The whole program is one loop on this task.
                        try body.program.source.run(body.env, Entry(Frame, S.Item){ .refs = refs });
                        try Frame.at.finish(refs, Closed{});
                    } else {
                        // The pipe crosses a task boundary: the source and
                        // every boundary's task run as members of one scope,
                        // and this task only waits. Each segment ends the
                        // stream for its own stages; all of them have
                        // returned before anything is flushed or torn down.
                        var scope: tasks.Scope = .{};
                        const feed: Feed(S, Env, Frame) = .{ .source = &body.program.source, .env = body.env, .refs = refs, .scope = &scope };
                        const segments = Frame.at.tasks(refs, Closed{}, &scope);
                        try scope.run(segments[0].io(), .{feed} ++ segments);
                    }
                    try Frame.at.flush(refs);
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env });
        }
    };
}

/// Segment 0 of a program whose pipe has a task boundary: the source and the
/// stages up to the first boundary.
fn Feed(comptime S: type, comptime Env: type, comptime Frame: type) type {
    return struct {
        source: *const S,
        env: Env,
        refs: Frame.Refs,
        scope: *tasks.Scope,

        pub fn run(feed: @This()) !void {
            try feed.source.run(feed.env, Entry(Frame, S.Item){ .refs = feed.refs });
            // An effect of a normal end must not follow a failure elsewhere.
            if (feed.scope.hasFailed()) return;
            try Frame.at.finish(feed.refs, Closed{});
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

/// Several programs (or systems) run together with the same dependencies,
/// each as a task (see `tasks.Scope`). Returns when all have completed; the
/// first failure cancels the rest. With more than one member, `std.Io` must
/// be among the dependencies and able to run tasks concurrently
/// (`error.ConcurrencyUnavailable` otherwise).
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
            var scope: tasks.Scope = .{};
            return scope.run(di.get(env, Io), group);
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
