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
                    try Frame.at.finish(refs, Closed{});
                    try Frame.at.flush(refs);
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env });
        }

        /// The pipe crosses a task boundary, so the source is a task too: when
        /// a worker ends on its own (its side failed, or wants no more), the
        /// source is cancelled instead of being left to find out at its next
        /// push, which for an idle source might never come.
        fn runSupervised(self: *const @This(), outer: anytype) !void {
            const io = di.get(outer, Io);
            var signal: core.Supervision.Signal = .{ .io = io };
            const env = di.extend(outer, core.Supervision{ .signal = &signal, .whole_pipe = true });
            const Env = @TypeOf(env);
            const Frame = P.Stage(Env, S.Item);
            const Feed = struct {
                fn run(source: *const S, feed_env: Env, entry: Entry(Frame, S.Item), wake: *core.Supervision.Signal, ended: *std.atomic.Value(bool)) !void {
                    defer {
                        ended.store(true, .release);
                        wake.wake.set(wake.io);
                    }
                    return source.run(feed_env, entry);
                }
            };
            const Body = struct {
                program: *const Program(S, P),
                env: Env,
                signal: *core.Supervision.Signal,

                pub fn call(body: @This(), refs: Frame.Refs) !void {
                    const body_io = body.signal.io;
                    try Frame.at.init(refs, &body.program.pipe.ops, body.env);
                    defer {
                        Frame.at.stop(refs);
                        Frame.at.deinit(refs);
                    }
                    try Frame.at.start(refs, Closed{});

                    var ended: std.atomic.Value(bool) = .init(false);
                    var source = try body_io.concurrent(Feed.run, .{
                        &body.program.source, body.env, Entry(Frame, S.Item){ .refs = refs }, body.signal, &ended,
                    });
                    body.signal.wake.wait(body_io) catch |err| {
                        // This task is being cancelled: so is the source.
                        source.cancel(body_io) catch {};
                        return err;
                    };
                    const ended_by_itself = ended.load(.acquire);
                    source.cancel(body_io) catch |err| {
                        // Cancelled by the line above because a worker ended:
                        // not a failure of the source. What the worker ended
                        // with comes out of `finish`.
                        const interrupted = !ended_by_itself and @as(anyerror, err) == error.Canceled;
                        if (!interrupted) return err;
                    };
                    try Frame.at.finish(refs, Closed{});
                    try Frame.at.flush(refs);
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env, .signal = &signal });
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
