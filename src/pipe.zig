//! Pipes: operators composed into one statically typed push chain.
//!
//! ## The operator contract
//!
//! An operator is a value whose type declares:
//!
//!     pub const zrx_operator = {};
//!     pub const name = "map";                                   // for diagnostics
//!     pub fn Out(comptime Env: type, comptime In: type) type    // item type sent on, or `End`
//!     pub fn Stage(comptime Env: type, comptime In: type) type  // its runtime state
//!     pub fn Provides(comptime Env: type) type                  // optional: Env seen downstream
//!
//! and whose `Stage` declares:
//!
//!     pub fn init(self: *Stage, op: *const Op, env: Env) !void
//!     pub fn push(self: *Stage, item: In, down: anytype) !Flow
//!     pub fn finish(self: *Stage, down: anytype) !void   // optional: the stream ended; last chance to push
//!     pub fn flush(self: *Stage) !void                   // optional: everything downstream has finished
//!     pub fn deinit(self: *Stage) void                   // optional: always runs, in reverse order
//!     pub fn provide(self: *Stage, env: Env) Provides(Env) // with `Provides`
//!
//! `down.push(value)` hands a value to the rest of the pipe and returns `Flow`.
//! `Env` and `In` are known when the stage type is built, so every check and
//! every call is resolved at compile time. A pipe is itself an operator, which
//! is all that nesting a pipe in a pipe means.
//!
//! A run goes: `init` every stage in order, `push` per item, then on a normal
//! end `finish` in order and `flush` in reverse; and always, last, `deinit` in
//! reverse. A failure skips `finish` and `flush`.
//!
//! ## Task boundaries
//!
//! A stage that hands its items to another task (`queue`) splits the pipe into
//! *segments*: what comes before it runs on one task, what follows it on the
//! stage's own. Such a stage also declares:
//!
//!     pub const zrx_boundary = {};
//!     pub fn work(self: *Stage, down: anytype) !void  // the task: feeds `down` until its input ends or `down` is done
//!     pub fn retire(self: *Stage) void                // the task is gone: `push` answers `.done` from now on
//!     pub fn taskIo(self: *Stage) Io                  // the `Io` its task is started and joined on
//!
//! Its `push` hands an item over and its `finish` says that no more will come.
//! The end of the stream then travels with the data: `finish` runs in order up
//! to and including a boundary, on the task that pushed into it; the boundary's
//! task, once `work` has returned, finishes the stages after it up to the next
//! one. No task finishes another's stages. A program runs every such task and
//! the source under one `tasks.Scope`, then flushes and tears down by itself.
//!
//! A boundary whose task is gone never keeps a producer waiting: `retire` is
//! called when `work` is over, however it ended (the input ran out, `down`
//! was done, it failed, it was cancelled). `work` itself only returns. What a
//! segment's end means, and in which order others get to see it, is decided
//! in one place for every task: `tasks.Scope`.
//!
//! A stage that holds sub-pipes (`branch`, `route`) says which tasks they need:
//!
//!     pub const has_boundary: bool                     // whether a sub-pipe has a boundary
//!     pub const sinks_directly: bool                   // whether a sub-pipe ends on the task that pushes into it
//!     pub fn Tasks(comptime Down: type) type           // `TasksOf` its chains
//!     pub fn tasks(self: *Stage, down: anytype, feeder: usize, first: usize) Tasks(@TypeOf(down))
//!
//! `feeder` is the index, among the scope's members, of the task that pushes
//! into the stage, and `first` the index of the first task returned. With
//! them each task says which one feeds it, and the scope cancels a task whose
//! every output is a boundary once the tasks behind those have returned: it
//! works for nothing. A terminal stage that does not declare `sinks_directly`
//! counts as ending on the task that pushes into it, so that task is never
//! cancelled that way.
//!
//! Keeping it free: return `down.push(x)` directly, or compare its result and
//! return a constant (`if (try down.push(x) == .done) return .done;`). Do not
//! store a `Flow` and later choose between it and a constant: `E!Flow` travels
//! through memory until inlining removes it, and that shape stops the
//! optimizer from doing so. `zig build zero-overhead` guards the operators here.
const std = @import("std");
const Io = std.Io;
const di = @import("di.zig");

/// What a push tells its caller: keep sending, or stop because nothing
/// downstream wants more. A stage that returned `.done` may still be pushed
/// to (by trailing emissions upstream) and keeps answering `.done`.
pub const Flow = enum { more, done };

/// The `Out` of a terminal operator: nothing flows past it.
pub const End = opaque {};

/// The `down` given to stages of a terminated pipe. It has no `push`.
pub const Closed = struct {};

pub fn isOperator(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_operator");
}

pub fn isPipe(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_pipe");
}

/// Whether `pipe` replaces an operator of type `T` by the operators in its `ops`.
fn isSpliced(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_spliced");
}

/// An operator made of several stages, for when its parts must be stages of
/// their own (see `batch`). `pipe` splices its `ops` in like a nested pipe's,
/// but it is one operator to its user, not a `pipe(...)`: where a sub-pipe is
/// expected it is rejected like any other bare operator.
pub fn Spliced(comptime operator_name: []const u8, comptime Ops: type) type {
    return struct {
        ops: Ops,

        pub const zrx_operator = {};
        pub const zrx_spliced = {};
        pub const name = operator_name;
    };
}

/// Whether any of the chains in the tuple type `Chains` has a task boundary.
pub fn anyBoundary(comptime Chains: type) bool {
    for (di.types(Chains)) |C| if (C.has_boundary) return true;
    return false;
}

/// Whether any of the chains in the tuple type `Chains` ends on the task that
/// pushes into it, without crossing a boundary.
pub fn anySinksDirectly(comptime Chains: type) bool {
    for (di.types(Chains)) |C| if (C.sinks_directly) return true;
    return false;
}

/// The tasks of the chains in the tuple type `Chains`, each of which pushes
/// into a `Tail`: what a stage with sub-pipes declares as its `Tasks`.
pub fn TasksOf(comptime Chains: type, comptime Tail: type) type {
    var list: []const type = &.{};
    for (di.types(Chains)) |C| list = list ++ di.types(C.Tasks(Tail));
    return @Tuple(list);
}

/// The tasks of `chains`, a pointer to a tuple of chains: what a stage with
/// sub-pipes returns from its `tasks`.
pub fn tasksOf(
    chains: anytype,
    tail: anytype,
    feeder: usize,
    first: usize,
) TasksOf(@typeInfo(@TypeOf(chains)).pointer.child, @TypeOf(tail)) {
    const Chains = @typeInfo(@TypeOf(chains)).pointer.child;
    var out: TasksOf(Chains, @TypeOf(tail)) = undefined;
    comptime var next = 0;
    inline for (0..comptime di.types(Chains).len) |i| {
        const inner = chains[i].tasks(tail, feeder, first + next);
        inline for (0..comptime di.types(@TypeOf(inner)).len) |k| {
            out[next] = inner[k];
            next += 1;
        }
    }
    return out;
}

/// For operators that take sub-pipelines.
pub fn expectPipe(comptime who: []const u8, comptime T: type) void {
    if (comptime !isPipe(T)) @compileError(who ++ ": expected `pipe(.{ ... })`, got `" ++ @typeName(T) ++ "`");
}

/// `try lift(x)` works whether or not `x` is an error union.
pub fn Lifted(comptime R: type) type {
    return if (@typeInfo(R) == .error_union) R else error{}!R;
}

pub inline fn lift(result: anytype) Lifted(@TypeOf(result)) {
    return result;
}

/// Composes operators left to right. `pipe(.{ a, pipe(.{ b, c }), d })` is
/// exactly `pipe(.{ a, b, c, d })`: a nested pipe is spliced in.
pub fn pipe(operators: anytype) Pipe(Operators(@TypeOf(operators))) {
    var ops: Operators(@TypeOf(operators)) = undefined;
    comptime var at = 0;
    inline for (0..operators.len) |i| {
        if (comptime isSpliced(@TypeOf(operators[i]))) {
            inline for (0..comptime di.types(@TypeOf(operators[i].ops)).len) |j| {
                ops[at] = operators[i].ops[j];
                at += 1;
            }
        } else {
            ops[at] = operators[i];
            at += 1;
        }
    }
    return .{ .ops = ops };
}

fn Operators(comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(Given)) @compileError("pipe: expected a tuple of operators `.{ ... }`, got `" ++ @typeName(Given) ++ "`");
    const given = di.types(Given);
    if (given.len == 0) @compileError("pipe: a pipe needs at least one operator");
    var ops: []const type = &.{};
    for (given, 0..) |Op, i| {
        if (!isOperator(Op)) @compileError(std.fmt.comptimePrint(
            "pipe: element {d} is not an operator (got `{s}`); a pipe holds operators such as map(...), filter(...) or another pipe",
            .{ i, @typeName(Op) },
        ));
        ops = ops ++ if (isSpliced(Op)) di.types(@FieldType(Op, "ops")) else &[_]type{Op};
    }
    return @Tuple(ops);
}

pub fn Pipe(comptime Ops: type) type {
    return struct {
        ops: Ops,

        pub const zrx_operator = {};
        pub const zrx_pipe = {};
        pub const zrx_spliced = {};
        pub const name = "pipe";

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            return plan(Ops, Env, In).items[di.types(Ops).len];
        }

        pub fn Provides(comptime Env: type) type {
            @setEvalBranchQuota(di.quota);
            var Current = Env;
            for (di.types(Ops)) |Op| {
                if (@hasDecl(Op, "Provides")) Current = Op.Provides(Current);
            }
            return Current;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            return Chain(Ops, Env, In);
        }
    };
}

fn Plan(comptime n: usize) type {
    return struct { items: [n + 1]type, envs: [n + 1]type };
}

/// The forward pass: the item type and environment each operator sees.
fn plan(comptime Ops: type, comptime Env: type, comptime In: type) Plan(di.types(Ops).len) {
    @setEvalBranchQuota(di.quota);
    const ops = di.types(Ops);
    var result: Plan(ops.len) = undefined;
    result.items[0] = In;
    result.envs[0] = Env;
    for (ops, 0..) |Op, i| {
        if (result.items[i] == End) @compileError(std.fmt.comptimePrint(
            "pipe: `{s}` at position {d} comes after the terminal operator `{s}`; nothing flows past a terminal operator",
            .{ Op.name, i, if (i == 0) "upstream" else ops[i - 1].name },
        ));
        result.items[i + 1] = Op.Out(result.envs[i], result.items[i]);
        result.envs[i + 1] = if (@hasDecl(Op, "Provides")) Op.Provides(result.envs[i]) else result.envs[i];
    }
    return result;
}

/// The runtime state of a pipe: one stage per operator.
///
/// Every function works on `Refs`, a tuple of pointers to the stages, so the
/// stages need not live together. A program gives each stage its own local
/// variable (`withLocals`): the optimizer then treats them independently, and
/// a stage it cannot keep in registers (one with an indexed buffer, say) does
/// not drag its neighbours into memory. Where a chain is itself a stage (a
/// sub-pipe of `branch` or `route`) it is stored as this struct.
///
/// Stages reach each other through `Down` handles: the `Refs` plus a comptime
/// index, so a push is a chain of direct calls.
fn Chain(comptime Ops: type, comptime Env: type, comptime In: type) type {
    @setEvalBranchQuota(di.quota);
    const ops = di.types(Ops);
    const n = ops.len;
    const types = plan(Ops, Env, In);
    const stages = blk: {
        var list: [n]type = undefined;
        for (ops, 0..) |Op, i| list[i] = Op.Stage(types.envs[i], types.items[i]);
        break :blk list;
    };
    const pointers = blk: {
        var list: [n]type = undefined;
        for (stages, 0..) |S, i| list[i] = *S;
        break :blk list;
    };

    return struct {
        states: @Tuple(&stages),

        const Self = @This();

        /// A pointer to every stage, in order.
        pub const Refs = @Tuple(&pointers);

        /// Whether part of this chain runs on another task (it contains a
        /// `queue`, in itself or in a sub-pipe).
        pub const has_boundary = blk: {
            for (stages) |S| {
                if (@hasDecl(S, "zrx_boundary")) break :blk true;
                if (@hasDecl(S, "has_boundary") and S.has_boundary) break :blk true;
            }
            break :blk false;
        };

        fn Down(comptime Tail: type, comptime i: usize) type {
            return struct {
                refs: Refs,
                tail: Tail,

                pub fn push(down: @This(), item: types.items[i]) !Flow {
                    if (i == n) {
                        return down.tail.push(item);
                    } else {
                        const next: Down(Tail, i + 1) = .{ .refs = down.refs, .tail = down.tail };
                        return down.refs[i].push(item, next);
                    }
                }
            };
        }

        /// The chain's operations, on stages wherever they live.
        pub const at = struct {
            pub fn init(refs: Refs, operators: *const Ops, env: Env) !void {
                return initFrom(0, refs, operators, env);
            }

            fn initFrom(comptime i: usize, refs: Refs, operators: *const Ops, env: types.envs[i]) !void {
                if (i == n) return;
                try refs[i].init(&operators[i], env);
                errdefer if (@hasDecl(stages[i], "deinit")) refs[i].deinit();
                const next = if (@hasDecl(stages[i], "provide")) refs[i].provide(env) else env;
                try initFrom(i + 1, refs, operators, next);
            }

            pub fn provide(refs: Refs, env: Env) types.envs[n] {
                return provideFrom(0, refs, env);
            }

            fn provideFrom(comptime i: usize, refs: Refs, env: types.envs[i]) types.envs[n] {
                if (i == n) return env;
                const next = if (@hasDecl(stages[i], "provide")) refs[i].provide(env) else env;
                return provideFrom(i + 1, refs, next);
            }

            pub fn push(refs: Refs, item: In, tail: anytype) !Flow {
                const first: Down(@TypeOf(tail), 0) = .{ .refs = refs, .tail = tail };
                return first.push(item);
            }

            /// The end of the stream, for the stages up to and including
            /// the first task boundary. What follows a boundary is finished
            /// by that boundary's task (`Segment`).
            pub fn finish(refs: Refs, tail: anytype) !void {
                return finishFrom(0, refs, tail);
            }

            /// One task per boundary in this chain and its sub-pipes, in
            /// order: members of a `Scope`, where the first of them has the
            /// index `first` and the task that pushes into this chain the
            /// index `feeder`.
            pub fn tasks(refs: Refs, tail: anytype, feeder: usize, first: usize) Tasks(@TypeOf(tail)) {
                var out: Tasks(@TypeOf(tail)) = undefined;
                // The task that runs the stage being looked at.
                var current = feeder;
                comptime var next = 0;
                inline for (0..n) |i| {
                    if (comptime @hasDecl(stages[i], "zrx_boundary")) {
                        out[next] = .{ .refs = refs, .tail = tail, .fed_by = current };
                        current = first + next;
                        next += 1;
                    } else if (comptime @hasDecl(stages[i], "Tasks")) {
                        const down: Down(@TypeOf(tail), i + 1) = .{ .refs = refs, .tail = tail };
                        const inner = refs[i].tasks(down, current, first + next);
                        inline for (0..comptime di.types(@TypeOf(inner)).len) |k| {
                            out[next] = inner[k];
                            next += 1;
                        }
                    }
                }
                return out;
            }

            /// After every `finish`: stages that own buffered output write it out, last stage first.
            pub fn flush(refs: Refs) !void {
                comptime var i = n;
                inline while (i > 0) {
                    i -= 1;
                    if (@hasDecl(stages[i], "flush")) try refs[i].flush();
                }
            }

            pub fn deinit(refs: Refs) void {
                comptime var i = n;
                inline while (i > 0) {
                    i -= 1;
                    if (@hasDecl(stages[i], "deinit")) refs[i].deinit();
                }
            }
        };

        /// Where the segment that begins at stage `from` ends: past the next
        /// task boundary, or at the end of the chain.
        fn segmentEnd(comptime from: usize) usize {
            for (from..n) |i| if (@hasDecl(stages[i], "zrx_boundary")) return i + 1;
            return n;
        }

        /// Whether an item pushed into stage `from` can come to an end on
        /// the same task: it reaches a terminal stage without crossing a
        /// boundary. A chain that rejoins a pipe ends nothing itself.
        fn sinksDirectlyFrom(comptime from: usize) bool {
            for (from..n) |i| {
                if (@hasDecl(stages[i], "zrx_boundary")) return false;
                if (types.items[i + 1] == End)
                    return if (@hasDecl(stages[i], "sinks_directly")) stages[i].sinks_directly else true;
            }
            return false;
        }

        /// Whether an item pushed into this chain can come to an end on the
        /// task that pushed it.
        pub const sinks_directly = sinksDirectlyFrom(0);

        fn finishFrom(comptime from: usize, refs: Refs, tail: anytype) !void {
            inline for (from..comptime segmentEnd(from)) |i| {
                if (@hasDecl(stages[i], "finish")) {
                    const next: Down(@TypeOf(tail), i + 1) = .{ .refs = refs, .tail = tail };
                    try refs[i].finish(next);
                }
            }
        }

        /// The member types of `at.tasks`.
        pub fn Tasks(comptime Tail: type) type {
            var list: []const type = &.{};
            for (stages, 0..) |S, i| {
                if (@hasDecl(S, "zrx_boundary")) {
                    list = list ++ &[_]type{Segment(Tail, i)};
                } else if (@hasDecl(S, "Tasks")) {
                    list = list ++ di.types(S.Tasks(Down(Tail, i + 1)));
                }
            }
            return @Tuple(list);
        }

        /// The task of the boundary stage `j`, as a member of a `Scope`:
        /// everything from that stage to the next boundary. Its work is to
        /// feed the stages after `j`; its end is the end of the stream for
        /// them. The scope decides when each happens.
        fn Segment(comptime Tail: type, comptime j: usize) type {
            return struct {
                refs: Refs,
                tail: Tail,
                /// The member that pushes into stage `j`.
                fed_by: usize,

                /// Everything this task puts out goes into another boundary.
                pub const feeds_only_members = !sinksDirectlyFrom(j + 1);

                pub fn io(segment: @This()) Io {
                    return segment.refs[j].taskIo();
                }

                pub fn run(segment: @This()) !void {
                    const down: Down(Tail, j + 1) = .{ .refs = segment.refs, .tail = segment.tail };
                    return segment.refs[j].work(down);
                }

                pub fn retire(segment: @This()) void {
                    segment.refs[j].retire();
                }

                pub fn end(segment: @This()) !void {
                    return finishFrom(j + 1, segment.refs, segment.tail);
                }
            };
        }

        /// Calls `body.call(refs)` with every stage in a local variable of its own.
        pub fn withLocals(body: anytype) @typeInfo(@TypeOf(@TypeOf(body).call)).@"fn".return_type.? {
            return locals(0, .{}, body);
        }

        fn locals(
            comptime i: usize,
            partial: @Tuple(pointers[0..i]),
            body: anytype,
        ) @typeInfo(@TypeOf(@TypeOf(body).call)).@"fn".return_type.? {
            if (i == n) return body.call(partial);
            var state: stages[i] = undefined;
            var next: @Tuple(pointers[0 .. i + 1]) = undefined;
            inline for (0..i) |k| next[k] = partial[k];
            next[i] = &state;
            return locals(i + 1, next, body);
        }

        // The same operations for a chain stored as one value: the stage contract.

        fn refsOf(self: *Self) Refs {
            var refs: Refs = undefined;
            inline for (0..n) |i| refs[i] = &self.states[i];
            return refs;
        }

        pub fn init(self: *Self, op: *const Pipe(Ops), env: Env) !void {
            return at.init(self.refsOf(), &op.ops, env);
        }

        pub fn provide(self: *Self, env: Env) types.envs[n] {
            return at.provide(self.refsOf(), env);
        }

        pub fn push(self: *Self, item: In, tail: anytype) !Flow {
            return at.push(self.refsOf(), item, tail);
        }

        pub fn finish(self: *Self, tail: anytype) !void {
            return at.finish(self.refsOf(), tail);
        }

        pub fn tasks(self: *Self, tail: anytype, feeder: usize, first: usize) Tasks(@TypeOf(tail)) {
            return at.tasks(self.refsOf(), tail, feeder, first);
        }

        pub fn flush(self: *Self) !void {
            return at.flush(self.refsOf());
        }

        pub fn deinit(self: *Self) void {
            at.deinit(self.refsOf());
        }
    };
}
