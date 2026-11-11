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
//!     pub fn start(self: *Stage, down: anytype) !void    // optional: after every stage is initialized
//!     pub fn finish(self: *Stage, down: anytype) !void   // optional: the stream ended; last chance to push
//!     pub fn flush(self: *Stage) !void                   // optional: everything downstream has finished
//!     pub fn stop(self: *Stage) void                     // optional: cancel and join any task this stage runs
//!     pub fn deinit(self: *Stage) void                   // optional: always runs, in reverse order
//!     pub fn provide(self: *Stage, env: Env) Provides(Env) // with `Provides`
//!
//! `down.push(value)` hands a value to the rest of the pipe and returns `Flow`.
//! `Env` and `In` are known when the stage type is built, so every check and
//! every call is resolved at compile time. A pipe is itself an operator, which
//! is all that nesting a pipe in a pipe means.
//!
//! A run goes: `init` every stage in order, `start` in reverse, `push` per
//! item, then on a normal end `finish` in order and `flush` in reverse; and
//! always, last, `stop` in order and then `deinit` in reverse. A failure skips
//! `finish` and `flush`. Every `stop` runs before any `deinit`, so no task is
//! still using a stage when that stage, or one after it, is torn down.
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

/// How a stage that runs a worker task tells the run that its worker ended on
/// its own, so that a source waiting for its next item is not left to find
/// out only when it pushes again. A program provides this dependency to its
/// stages when its pipe crosses a task boundary.
pub const Supervision = struct {
    signal: *Signal,
    /// False inside a `branch` or `route` sub-pipe, where one sub-pipe
    /// wanting no more says nothing about its siblings.
    whole_pipe: bool,

    pub const Signal = struct {
        io: Io,
        wake: Io.Event = .unset,
    };

    /// The worker's side of the pipe failed: the run is over.
    pub fn failed(supervision: Supervision) void {
        supervision.signal.wake.set(supervision.signal.io);
    }

    /// The worker's side of the pipe wants no more items.
    pub fn satisfied(supervision: Supervision) void {
        if (supervision.whole_pipe) supervision.signal.wake.set(supervision.signal.io);
    }

    /// What a stage with sub-pipes provides to them in its place.
    pub fn nested(supervision: Supervision) Supervision {
        return .{ .signal = supervision.signal, .whole_pipe = false };
    }

    /// `env` as a sub-pipe of a `branch` or `route` should see it.
    pub fn nest(env: anytype) @TypeOf(env) {
        if (comptime !di.has(@TypeOf(env), Supervision)) return env;
        return di.extend(env, di.get(env, Supervision).nested());
    }
};

pub fn isOperator(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_operator");
}

pub fn isPipe(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_pipe");
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
        if (comptime isPipe(@TypeOf(operators[i]))) {
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
        ops = ops ++ if (isPipe(Op)) di.types(@FieldType(Op, "ops")) else &[_]type{Op};
    }
    return @Tuple(ops);
}

pub fn Pipe(comptime Ops: type) type {
    return struct {
        ops: Ops,

        pub const zrx_operator = {};
        pub const zrx_pipe = {};
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

        /// Whether part of this chain runs on another task (it contains a `queue`).
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

            pub fn start(refs: Refs, tail: anytype) !void {
                comptime var i = n;
                inline while (i > 0) {
                    i -= 1;
                    if (@hasDecl(stages[i], "start")) {
                        const next: Down(@TypeOf(tail), i + 1) = .{ .refs = refs, .tail = tail };
                        try refs[i].start(next);
                    }
                }
            }

            pub fn push(refs: Refs, item: In, tail: anytype) !Flow {
                const first: Down(@TypeOf(tail), 0) = .{ .refs = refs, .tail = tail };
                return first.push(item);
            }

            pub fn finish(refs: Refs, tail: anytype) !void {
                inline for (0..n) |i| {
                    if (@hasDecl(stages[i], "finish")) {
                        const next: Down(@TypeOf(tail), i + 1) = .{ .refs = refs, .tail = tail };
                        try refs[i].finish(next);
                    }
                }
            }

            /// After every `finish`: stages that own buffered output write it out, last stage first.
            pub fn flush(refs: Refs) !void {
                comptime var i = n;
                inline while (i > 0) {
                    i -= 1;
                    if (@hasDecl(stages[i], "flush")) try refs[i].flush();
                }
            }

            /// Before any `deinit`: every task a stage runs is cancelled and joined.
            pub fn stop(refs: Refs) void {
                inline for (0..n) |i| {
                    if (@hasDecl(stages[i], "stop")) refs[i].stop();
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

        pub fn start(self: *Self, tail: anytype) !void {
            return at.start(self.refsOf(), tail);
        }

        pub fn push(self: *Self, item: In, tail: anytype) !Flow {
            return at.push(self.refsOf(), item, tail);
        }

        pub fn finish(self: *Self, tail: anytype) !void {
            return at.finish(self.refsOf(), tail);
        }

        pub fn flush(self: *Self) !void {
            return at.flush(self.refsOf());
        }

        pub fn stop(self: *Self) void {
            at.stop(self.refsOf());
        }

        pub fn deinit(self: *Self) void {
            at.deinit(self.refsOf());
        }
    };
}
