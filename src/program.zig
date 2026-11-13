//! Programs: a source bound to a terminated pipe, run with its dependencies.
const di = @import("di.zig");
const core = @import("pipe.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;

pub fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_source");
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
                    try body.program.source.run(body.env, Entry(Frame, S.Item){ .refs = refs });
                    try Frame.at.finish(refs, Closed{});
                }
            };
            return Frame.withLocals(Body{ .program = self, .env = env });
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
