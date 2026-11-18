//! Programs: a source bound to a terminated pipe, run with its dependencies.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const resources = @import("resources.zig");
const tasks = @import("tasks.zig");
const completion = @import("completion.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;

pub fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_source");
}

pub fn isProgram(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_program");
}

/// One source feeding an operator tuple or a constructed pipe. It must terminate.
/// Nothing happens until `run`.
pub fn program(source: anytype, pipeline: anytype) Program(@TypeOf(source), core.NormalizedPipe("program", @TypeOf(pipeline)), @Tuple(&.{})) {
    return .{ .source = source, .pipe = core.normalizePipe("program", pipeline), .bindings = .{} };
}

pub fn Program(comptime S: type, comptime P: type, comptime Bindings: type) type {
    @setEvalBranchQuota(di.quota);
    if (!isSource(S)) @compileError("program: the first argument must be a source such as fromSlice(...), got `" ++ @typeName(S) ++ "`");
    return struct {
        source: S,
        pipe: P,
        bindings: Bindings,

        pub const zrx_program = {};

        const Self = @This();

        /// Binds values and resources for the source and every stage of this program.
        pub fn provide(self: *const Self, bindings: anytype) Program(S, P, Joined(Bindings, @TypeOf(bindings))) {
            return .{ .source = self.source, .pipe = self.pipe, .bindings = self.bindings ++ bindings };
        }

        /// Runs with additional caller-supplied dependencies.
        pub fn run(self: *const Self, deps: anytype) !void {
            const Run = struct {
                program: *const Self,

                pub fn call(body: @This(), env: anytype) !void {
                    return body.program.runBound(env);
                }
            };
            return resources.run(self.bindings, di.normalize(deps), Run{ .program = self });
        }

        fn runBound(self: *const Self, env: anytype) !void {
            const Env = @TypeOf(env);
            const Out = P.Out(Env, S.Item);
            if (Out != End) @compileError(
                "program: the pipe must terminate, but it still emits `" ++ @typeName(Out) ++
                    "`; end it with forEach(...), drain() or another terminal operator",
            );

            const wants_stop = comptime completion.sourceWantsStop(S);
            const tracks_demand = comptime wants_stop and P.Stage(Env, S.Item).has_boundary;
            const StageEnv = if (tracks_demand) di.Extend(Env, completion.Track) else Env;
            const SourceEnv = if (wants_stop) di.Extend(Env, completion.Stop) else Env;
            const Frame = P.Stage(StageEnv, S.Item);
            const Body = struct {
                program: *const Self,
                env: Env,

                pub fn call(body: @This(), refs: Frame.Refs) !void {
                    const stage_env = if (tracks_demand) di.extend(body.env, completion.Track{}) else body.env;
                    Frame.at.init(refs, &body.program.pipe.ops, stage_env);
                    if (comptime !Frame.has_boundary) {
                        // The whole program is one loop on this task.
                        const source_env = if (wants_stop) di.extend(body.env, completion.Stop{}) else body.env;
                        try body.program.source.run(source_env, Entry(Frame, S.Item){ .refs = refs });
                        try Frame.at.finish(refs, Closed{});
                    } else {
                        // The pipe crosses a task boundary: the source and
                        // every boundary's task run as members of one scope,
                        // and this task only waits. Each segment ends the
                        // stream for its own stages; all of them have
                        // returned before program resources are released.
                        // The feed runs on the `Io` of the first boundary.
                        var signal: if (tracks_demand) completion.Signal else void = undefined;
                        var root: if (tracks_demand) completion.Demand else void = if (tracks_demand) .{ .signal = &signal } else {};
                        var nodes: if (tracks_demand) [di.types(Frame.Tasks(Closed)).len]completion.Demand else void = undefined;
                        const segments = if (tracks_demand) tracked: {
                            var slots: []completion.Demand = &nodes;
                            break :tracked Frame.at.collectTasks(refs, Closed{}, .{ .owner = &root, .nodes = &slots });
                        } else Frame.at.tasks(refs, Closed{});
                        const io = segments[0].io();
                        if (tracks_demand) signal = .{ .io = io };
                        const source_env = if (wants_stop) di.extend(body.env, completion.Stop{ .signal = &signal }) else body.env;
                        const feed: Feed(S, SourceEnv, Frame) = .{ .source = &body.program.source, .env = source_env, .refs = refs, .on = io };
                        var scope: tasks.Scope = .{};
                        try scope.run(io, .{feed} ++ segments);
                    }
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env });
        }
    };
}

fn Joined(comptime A: type, comptime B: type) type {
    if (!di.isTuple(B)) @compileError("program.provide: expected a tuple of bindings such as `.{ logger }`");
    return @Tuple(di.types(A) ++ di.types(B));
}

/// Segment 0 of a program whose pipe has a task boundary, as a member of a
/// `tasks.Scope`: the source and the stages up to the first boundary. Its
/// work is the source; its end is the end of the stream for those stages.
fn Feed(comptime S: type, comptime Env: type, comptime Frame: type) type {
    return struct {
        source: *const S,
        env: Env,
        refs: Frame.Refs,
        on: Io,

        pub fn io(feed: @This()) Io {
            return feed.on;
        }

        pub fn run(feed: @This()) !void {
            return feed.source.run(feed.env, Entry(Frame, S.Item){ .refs = feed.refs });
        }

        pub fn end(feed: @This()) !void {
            return Frame.at.finish(feed.refs, Closed{});
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
