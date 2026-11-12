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
//!     pub fn start(self: *Stage, down: anytype) !Flow    // optional: after every stage is initialized
//!     pub fn finish(self: *Stage, down: anytype) !void   // optional: the stream ended; last chance to push
//!     pub fn flush(self: *Stage) !void                   // optional: everything downstream has finished
//!     pub fn stop(self: *Stage) void                     // optional: cancel and join any task this stage runs
//!     pub fn failure(self: *Stage, down: anytype) !void  // with a worker: the error it ended with, if any
//!     pub fn takesNoMore(self: *Stage) bool              // optional: would answer `.done`, without being pushed to
//!     pub fn settle(self: *Stage, after_is_done: bool) bool // optional: told whether what follows it takes no more
//!     pub fn deinit(self: *Stage) void                   // optional: always runs, in reverse order
//!     pub fn provide(self: *Stage, env: Env) Provides(Env) // with `Provides`
//!
//! `down.push(value)` hands a value to the rest of the pipe and returns `Flow`.
//! `Env` and `In` are known when the stage type is built, so every check and
//! every call is resolved at compile time. A pipe is itself an operator, which
//! is all that nesting a pipe in a pipe means.
//!
//! A run goes: `init` every stage in order, `start` in reverse, `push` per
//! item, then on a normal end `finish` in order (each stage once, even when
//! a supervised run takes the end of the stream up again after interrupting
//! a final value that was for nothing) and `flush` in reverse; and
//! always, last, `stop` in order and then `deinit` in reverse. A failure skips
//! `finish` and `flush`. Every `stop` runs before any `deinit`, so no task is
//! still using a stage when that stage, or one after it, is torn down.
//!
//! In `start` and `finish` a stage emits with the same `down.push`. The chain
//! remembers when what follows a stage has answered `.done` and from then on
//! answers such an emission itself, so no stage after it runs for a value
//! nobody takes; a stage does not have to guard that.
//!
//! `start` answers like a push: `.done` when the stage takes no more items,
//! which a stage learns from a push it made (`return down.push(x)`), and
//! `.more` otherwise. When the pipe is done before startup is over, startup
//! is cut short there and the source is never run: `finish` can then reach a
//! stage whose `start` was interrupted or never ran, and has to cope with
//! that (an unstarted `queue` takes nothing).
//!
//! A stage that runs a task takes part in the run's `Supervision` (see below):
//! it reports when its worker ends and why, and joins it through the
//! supervision so that the join gives way to a failure elsewhere.
//!
//! `takesNoMore` and `settle` are how "done" travels against the flow when
//! nothing is being pushed. Both are called from whichever task needs to
//! know, the supervising one included, so they must be safe to call from any
//! task and must not block. `queue` answers `takesNoMore` once its far side
//! is done, and on `settle(true)` stops taking items and lets go of its
//! worker; `branch` and `route` answer for their sub-pipes and pass `settle`
//! on to them.
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
/// downstream wants more. Done is final, and whoever is answered `.done`
/// stops pushing: a source ends, a stage passes the answer on, and the chain
/// drops what a stage emits afterwards outside of `push` (see `Late`). A
/// stage that answers `.done` of its own accord (`take`) keeps doing so,
/// should a stage before it ignore the answer and push again.
pub const Flow = enum { more, done };

/// Whether a handle of type `T` (a `down`, or the tail of a chain) can say
/// that what it pushes into is done:
///
///     pub const zrx_answers_done = {};
///     pub fn isDone(self: T) bool
///
/// Only a handle that declares so is asked, and it may be a pointer to what
/// declares it, as it may for `push`. A handle is otherwise anything with a
/// `push`, and what else it declares is its own.
///
/// Whoever is told remembers: the answer need not be given twice, nor by the
/// same handle (an operator may pass a different one in each hook).
pub fn answersDone(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "zrx_answers_done"),
        .pointer => |pointer| pointer.size == .one and
            @typeInfo(pointer.child) == .@"struct" and @hasDecl(pointer.child, "zrx_answers_done"),
        else => false,
    };
}

/// The `Out` of a terminal operator: nothing flows past it.
pub const End = opaque {};

/// The `down` given to stages of a terminated pipe. It has no `push`.
pub const Closed = struct {};

/// The supervision of a run whose pipe crosses a task boundary: how its tasks
/// find out about each other without waiting for an item to be pushed.
///
/// A program provides this dependency to its stages. A stage that runs a
/// worker reports through it when the worker ends, and waits through it when
/// it joins the worker. `branch` and `route` give each sub-pipe a `Supervision`
/// scoped to them, so that "this sub-pipe wants no more" only becomes "the
/// pipe wants no more" once it is true of every sub-pipe.
pub const Supervision = struct {
    signal: *Signal,
    /// The `branch` or `route` this pipe is a sub-pipe of, and which one it is.
    scope: ?*Scope = null,
    arm: usize = 0,

    pub const Signal = struct {
        mutex: Io.Mutex = .init,
        changed: Io.Condition = .init,
        /// The `Io` of the first stage that will run a worker. The run waits
        /// with it, so `Io` only has to be provided where a worker needs it.
        io: ?Io = null,
        /// The first stage whose worker failed. The run returns that
        /// stage's `failure`.
        failed_stage: ?*const anyopaque = null,
        has_failed: std.atomic.Value(bool) = .init(false),
        /// Nothing in the pipe wants another item.
        satisfied: bool = false,
        has_satisfied: std.atomic.Value(bool) = .init(false),
        /// Counts what workers have said about being done, at any depth:
        /// the run settles the pipe again when this has moved.
        news: usize = 0,
        /// The task running the stages' `start` hooks has returned.
        starting_ended: bool = false,
        /// The task feeding the pipe from the source has returned.
        feeding_ended: bool = false,
        /// The task finishing and flushing the pipe has returned.
        ending_ended: bool = false,

        fn update(signal: *Signal, io: Io, comptime change: fn (*Signal) void) void {
            signal.mutex.lockUncancelable(io);
            defer signal.mutex.unlock(io);
            change(signal);
            signal.changed.broadcast(io);
        }
    };

    pub const Scope = struct {
        parent: Supervision,
        /// One flag per sub-pipe: it wants no more items.
        done: []std.atomic.Value(bool),
    };

    /// This stage will run a worker, using `io`. Called from `init`, so that
    /// the run has an `Io` to supervise with before any stage is started.
    pub fn adopt(supervision: Supervision, io: Io) void {
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        if (signal.io == null) signal.io = io;
    }

    /// The worker of `stage` (a pointer to it) failed: the run is over, and
    /// unless another worker failed first, its result is what
    /// `stage.failure(down)` returns.
    ///
    /// The error itself is not passed here. It is returned by the stage, from
    /// a function of the stage's own type, so the compiler knows which errors
    /// a run can end with; a stage that reports a failure it cannot return
    /// does not compile.
    pub fn fail(supervision: Supervision, io: Io, stage: anytype) void {
        const Stage = @typeInfo(@TypeOf(stage)).pointer.child;
        if (comptime !@hasDecl(Stage, "failure")) @compileError(
            "Supervision.fail: `" ++ @typeName(Stage) ++ "` reports a worker failure, so it must declare " ++
                "`pub fn failure(self: *Stage, down: anytype) !void` returning the error its worker ended with",
        );
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        if (signal.failed_stage == null) {
            signal.failed_stage = @ptrCast(stage);
            signal.has_failed.store(true, .release);
        }
        signal.changed.broadcast(io);
    }

    /// Whether nothing in the pipe wants another item.
    pub fn isSatisfied(supervision: Supervision, io: Io) bool {
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        return signal.satisfied;
    }

    /// The stage whose worker failed first, if any has.
    pub fn failedStage(supervision: Supervision, io: Io) ?*const anyopaque {
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        return signal.failed_stage;
    }

    /// A worker's side of the pipe wants no more items. Whether that makes
    /// the whole pipe done or only a sub-pipe, the run is told: what comes
    /// before that worker may be working, or waiting, for nothing.
    pub fn satisfy(supervision: Supervision, io: Io) void {
        var current = supervision;
        while (current.scope) |scope| {
            scope.done[current.arm].store(true, .seq_cst);
            for (scope.done) |*done| if (!done.load(.seq_cst)) {
                return current.signal.update(io, struct {
                    fn change(signal: *Signal) void {
                        signal.news += 1;
                    }
                }.change);
            };
            current = scope.parent;
        }
        current.signal.update(io, struct {
            fn change(signal: *Signal) void {
                signal.satisfied = true;
                signal.has_satisfied.store(true, .release);
                signal.news += 1;
            }
        }.change);
    }

    /// The run has settled the pipe (`Chain.at.settle`): wakes whoever waits
    /// for a worker that may have been let go of.
    pub fn settled(supervision: Supervision, io: Io) void {
        supervision.signal.update(io, struct {
            fn change(_: *Signal) void {}
        }.change);
    }

    /// A worker has returned; `ended` is the flag its stage waits on.
    pub fn workerEnded(supervision: Supervision, io: Io, ended: *bool) void {
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        ended.* = true;
        signal.changed.broadcast(io);
    }

    /// Whether any worker has failed. Cheap: read before running an effect
    /// that should not happen once the run has failed.
    pub fn hasFailed(supervision: Supervision) bool {
        return supervision.signal.has_failed.load(.acquire);
    }

    /// Whether this pipe wants no more items, as far as workers have said:
    /// this sub-pipe of a `branch` or `route`, or any pipe it lies in (an
    /// arm that is done takes nothing for anything inside it, however
    /// deep). Cheap: read before starting a stage, which nothing should do
    /// for a pipe that is done.
    pub fn wantsNoMore(supervision: Supervision) bool {
        var current = supervision;
        while (current.scope) |scope| {
            if (scope.done[current.arm].load(.seq_cst)) return true;
            current = scope.parent;
        }
        return current.signal.has_satisfied.load(.acquire);
    }

    /// How a wait for a worker ended.
    pub const Awaited = enum {
        /// It returned.
        ended,
        /// It did not, and what it works for is no longer wanted.
        released,
        /// It did not, and another worker failed: the run is over.
        failed_elsewhere,
    };

    /// Waits for the worker that reports through `ended`, unless it has been
    /// let go of (`released`) or another worker failed first: then the wait
    /// is over, the worker is not.
    pub fn awaitWorker(supervision: Supervision, io: Io, ended: *const bool, released: *const std.atomic.Value(bool)) Io.Cancelable!Awaited {
        const signal = supervision.signal;
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        while (true) {
            if (ended.*) return .ended;
            if (signal.failed_stage != null) return .failed_elsewhere;
            if (released.load(.acquire)) return .released;
            try signal.changed.wait(io, &signal.mutex);
        }
    }
};

/// What `branch` and `route` keep about their `n` sub-pipes: which still want
/// items and, in a supervised run, the scope their workers report to.
pub fn Arms(comptime n: usize, comptime Env: type) type {
    const supervised = di.has(Env, Supervision);
    return struct {
        live: if (supervised) void else [n]bool,
        /// No sub-pipe is live. `route` asks this ahead of its per-item work,
        /// where one flag is free and walking `live` makes the optimizer
        /// reshape the loop.
        idle: if (supervised) void else bool,
        done: if (supervised) [n]std.atomic.Value(bool) else void,
        scope: if (supervised) Supervision.Scope else void,

        const Self = @This();
        pub const Guard = if (supervised) Supervision else void;

        pub fn init(self: *Self, env: Env) void {
            if (supervised) {
                self.live = {};
                self.idle = {};
                for (&self.done) |*done| done.* = .init(false);
                self.scope = .{ .parent = di.get(env, Supervision), .done = &self.done };
            } else {
                self.live = @splat(true);
                self.idle = false;
                self.done = {};
                self.scope = {};
            }
        }

        /// The environment sub-pipe `i` is built with.
        pub fn envFor(self: *Self, outer: Env, comptime i: usize) Env {
            if (!supervised) return outer;
            return di.extend(outer, self.guardOf(i));
        }

        /// What to start sub-pipe `i` with, so it stops starting stages once
        /// its workers have said it wants no more.
        pub fn guardOf(self: *Self, comptime i: usize) Guard {
            if (!supervised) return {};
            return .{ .signal = self.scope.parent.signal, .scope = &self.scope, .arm = i };
        }

        pub fn wants(self: *const Self, comptime i: usize) bool {
            return if (supervised) !self.done[i].load(.seq_cst) else self.live[i];
        }

        pub fn finished(self: *Self, comptime i: usize) void {
            if (supervised) return self.done[i].store(true, .seq_cst);
            self.live[i] = false;
            inline for (0..n) |k| if (self.live[k]) return;
            self.idle = true;
        }

        /// The pipe after a rejoining route is done: no sub-pipe is handed another item.
        pub fn finishAll(self: *Self) void {
            inline for (0..n) |i| self.finished(i);
        }

        pub fn anyWants(self: *const Self) bool {
            if (!supervised) return !self.idle;
            inline for (0..n) |i| if (self.wants(i)) return true;
            return false;
        }

        /// Whether a failure that came out of sub-pipe `i` no longer matters:
        /// a worker has said meanwhile that the sub-pipe wants no more, so
        /// what failed was for an item nobody takes. Being cancelled always
        /// matters. Without workers this cannot happen.
        pub fn moot(self: *const Self, comptime i: usize, err: anyerror) bool {
            if (!supervised) return false;
            return err != error.Canceled and !self.wants(i);
        }

        /// What to hand a sub-pipe's `finish`, so it stops once the run has failed.
        pub fn guard(self: *const Self) Guard {
            return if (supervised) self.scope.parent else {};
        }
    };
}

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

/// A final value of a stage, as the run sees it.
const Emission = enum(u8) {
    idle,
    /// On its way through the stages after the one that emitted it.
    under_way,
    /// Under way into something that takes no more: the run has marked it
    /// and is interrupting the task that emits it.
    interrupted,
};

/// What settling a chain found (`Chain.at.settle`).
pub const Settled = struct {
    /// The chain takes no more.
    done: bool,
    /// A final value was under way for nothing and has been marked: the
    /// task finishing the pipe must be interrupted.
    interrupted: bool,
};

/// Whether a stage of type `S` can push outside of its `push`.
fn emitsLate(comptime S: type) bool {
    return @hasDecl(S, "start") or @hasDecl(S, "finish");
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
    // A stage that can push outside of its `push` (as the run starts, as the
    // stream ends) is stored with one flag beside it: what follows the stage
    // has answered `.done`. In a supervised run, where the end of the stream
    // may be taken up again after being interrupted, also whether the stage
    // has finished and whether a final value of it is under way.
    const supervised = di.has(Env, Supervision);
    const slots = blk: {
        var list: [n]type = undefined;
        for (stages, 0..) |S, i| list[i] = if (!emitsLate(S))
            S
        else if (supervised)
            struct { stage: S, after_is_done: bool, finished: bool, emission: std.atomic.Value(Emission) }
        else
            struct { stage: S, after_is_done: bool };
        break :blk list;
    };

    return struct {
        states: @Tuple(&slots),

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

        /// What is stored beside stage `i`, which emits outside of `push`.
        fn slotOf(refs: Refs, comptime i: usize) *slots[i] {
            return @fieldParentPtr("stage", refs[i]);
        }

        fn afterIsDone(refs: Refs, comptime i: usize) *bool {
            return &slotOf(refs, i).after_is_done;
        }

        /// What follows each of the stages before `end` is done.
        fn closeFrom(refs: Refs, comptime end: usize) void {
            inline for (0..end) |k| {
                if (comptime emitsLate(stages[k])) afterIsDone(refs, k).* = true;
            }
        }

        /// What a stage pushes an item on with: to stage `i`, or past the
        /// last one to the chain's tail. A `.done` answer is remembered on
        /// its way back, where a later emission could ask.
        fn Down(comptime Tail: type, comptime i: usize) type {
            return struct {
                refs: Refs,
                tail: Tail,

                pub fn push(down: @This(), item: types.items[i]) !Flow {
                    if (comptime i == 0 or !emitsLate(stages[i - 1])) return down.forward(item);
                    if (try down.forward(item) == .done) {
                        afterIsDone(down.refs, i - 1).* = true;
                        return .done;
                    }
                    return .more;
                }

                fn forward(down: @This(), item: types.items[i]) !Flow {
                    if (i == n) {
                        return down.tail.push(item);
                    } else {
                        const next: Down(Tail, i + 1) = .{ .refs = down.refs, .tail = down.tail };
                        return down.refs[i].push(item, next);
                    }
                }
            };
        }

        /// What a stage emits with outside of `push`: as the run starts and
        /// as the stream ends. Done is final: once what follows the stage
        /// has answered `.done`, nothing is pushed there again, and no stage
        /// after it runs for the value. (While items flow there is nothing
        /// to check: whoever was answered `.done` stops pushing.)
        fn Late(comptime Tail: type, comptime i: usize, comptime finishing: bool) type {
            return struct {
                refs: Refs,
                tail: Tail,

                pub const zrx_answers_done = {};

                /// Whether the run can interrupt this emission: a final
                /// value, in a supervised run. (As the run starts, the
                /// handle may be kept by a worker and used from its task.)
                const interruptible = finishing and supervised;

                pub fn push(late: @This(), item: types.items[i]) !Flow {
                    if (late.isDone()) return .done;
                    const down: Down(Tail, i) = .{ .refs = late.refs, .tail = late.tail };
                    if (!interruptible) return down.push(item);

                    // The value is under way from here to where `down.push`
                    // returns. If what it is pushed into comes to take no
                    // more meanwhile, the run interrupts it (`at.settle`),
                    // and then nothing that came back counts: not having
                    // been cancelled in a handler, not a handler's failure.
                    const emission = &slotOf(late.refs, i - 1).emission;
                    emission.store(.under_way, .release);
                    const answer = down.push(item) catch |err| {
                        if (emission.cmpxchgStrong(.under_way, .idle, .acq_rel, .acquire) != null) return late.forNothing();
                        // Not interrupted, but the same may have become
                        // true by now: a failure over a value nobody takes
                        // is not the run's. Being cancelled always counts.
                        if (@as(anyerror, err) != error.Canceled and late.isDone()) return .done;
                        return err;
                    };
                    if (emission.cmpxchgStrong(.under_way, .idle, .acq_rel, .acquire) != null) return late.forNothing();
                    return answer;
                }

                /// The run interrupted this emission. `finish` sees the mark
                /// when the stage's hook returns, and hands the end of the
                /// stream back to the run.
                fn forNothing(late: @This()) Flow {
                    afterIsDone(late.refs, i - 1).* = true;
                    return .done;
                }

                /// Whether an emission would get nowhere: what follows the
                /// stage has answered `.done`, or what this chain emits into
                /// has. The second is for a chain that rejoins a pipe
                /// (a `route` case): its tail says whether that pipe is done,
                /// and then no stage of this chain should run for a value
                /// that would only be refused at the end of it.
                pub fn isDone(late: @This()) bool {
                    if (afterIsDone(late.refs, i - 1).*) return true;
                    // A later stage that can tell without being pushed to
                    // (a queue whose far side is done): everything from here
                    // on leads to it.
                    inline for (i..n) |k| {
                        if (@hasDecl(stages[k], "takesNoMore")) {
                            if (late.refs[k].takesNoMore()) {
                                afterIsDone(late.refs, i - 1).* = true;
                                return true;
                            }
                        }
                    }
                    if (comptime !answersDone(Tail)) return false;
                    if (!late.tail.isDone()) return false;
                    // Remembered for every stage: the tail given next time
                    // may be one that cannot be asked.
                    closeFrom(late.refs, n);
                    return true;
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
                if (comptime emitsLate(stages[i])) {
                    afterIsDone(refs, i).* = false;
                    if (supervised) {
                        slotOf(refs, i).finished = false;
                        slotOf(refs, i).emission = .init(.idle);
                    }
                }
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

            /// Starts the stages, last first. `.done` when a stage answered
            /// that it takes no more items: then no source item can get
            /// anywhere either, the stages before it are not started, and
            /// nothing they emit later is pushed on. What the stage itself
            /// emits later is another matter (a `route` that takes no more
            /// items still emits its cases' final values): only an answer
            /// from what follows it closes that.
            ///
            /// `guard` is this pipe's `Supervision`, or `{}`. With it, no
            /// stage is started once a worker has failed (`error.Canceled`
            /// then stands for "the run failed elsewhere", as in `finish`),
            /// nor once a worker has said the pipe wants no more: a stage
            /// already started is behind a queue that has, so the same
            /// holds as for an answer, for this stage as well.
            pub fn start(refs: Refs, tail: anytype, guard: anytype) !Flow {
                comptime var i = n;
                inline while (i > 0) {
                    i -= 1;
                    if (@hasDecl(stages[i], "start")) {
                        if (@TypeOf(guard) == Supervision) {
                            if (guard.hasFailed()) return error.Canceled;
                            if (guard.wantsNoMore()) {
                                closeFrom(refs, i + 1);
                                return .done;
                            }
                        }
                        const next: Late(@TypeOf(tail), i + 1, false) = .{ .refs = refs, .tail = tail };
                        const answer = try refs[i].start(next);
                        if (comptime @TypeOf(answer) != Flow) @compileError(
                            "pipe: `" ++ ops[i].name ++ "` has a `start` that returns `" ++ @typeName(@TypeOf(answer)) ++
                                "`; it must return `!Flow`: what a push it made was answered (`return down.push(x)`), or `.more`",
                        );
                        if (answer == .done) {
                            closeFrom(refs, i);
                            return .done;
                        }
                    }
                }
                return .more;
            }

            pub fn push(refs: Refs, item: In, tail: anytype) !Flow {
                const first: Down(@TypeOf(tail), 0) = .{ .refs = refs, .tail = tail };
                return first.push(item);
            }

            /// Carries "done" against the flow: tells every stage whether
            /// something after it takes no more (`after_is_done` for the
            /// last one), and answers whether this chain itself takes no
            /// more. A supervised run does this whenever a worker has said
            /// it is done, so that a queue before that worker stops taking
            /// items and lets go of a worker that may be stuck in a handler.
            /// Called from the supervising task while stages run.
            pub fn settle(refs: Refs, after_is_done: bool) Settled {
                var settled: Settled = .{ .done = after_is_done, .interrupted = false };
                comptime var k = n;
                inline while (k > 0) {
                    k -= 1;
                    if (@hasDecl(stages[k], "settle")) {
                        if (refs[k].settle(settled.done)) settled.interrupted = true;
                    }
                    // A final value of this stage that is under way into
                    // something that takes no more is for nothing: marked
                    // here, so that the run interrupts whoever emits it.
                    if (supervised and comptime emitsLate(stages[k])) {
                        if (settled.done) {
                            if (slotOf(refs, k).emission.cmpxchgStrong(.under_way, .interrupted, .acq_rel, .acquire) == null)
                                settled.interrupted = true;
                        }
                    }
                    if (@hasDecl(stages[k], "takesNoMore")) {
                        if (refs[k].takesNoMore()) settled.done = true;
                    }
                }
                return settled;
            }

            /// `guard` is the run's `Supervision`, or `{}`. With it, once a
            /// worker has failed no further stage finishes: an effect of a
            /// normal end must not follow a failure. `error.Canceled` then
            /// stands for "the run failed elsewhere"; the program returns
            /// that failure instead.
            ///
            /// In a supervised run the end of the stream can be taken up
            /// again: a stage whose `finish` has returned is not finished
            /// twice. That is how the run gets past a final value that was
            /// under way when what it was pushed into came to take no more:
            /// it interrupts the task (the one request a task can be sent),
            /// the stage counts as finished, `error.Canceled` hands the end
            /// back, and the run starts it again from the next stage.
            pub fn finish(refs: Refs, tail: anytype, guard: anytype) !void {
                inline for (0..n) |i| {
                    if (@hasDecl(stages[i], "finish")) again: {
                        if (supervised) {
                            if (slotOf(refs, i).finished) break :again;
                        }
                        if (@TypeOf(guard) == Supervision) {
                            if (guard.hasFailed()) return error.Canceled;
                        }
                        const next: Late(@TypeOf(tail), i + 1, true) = .{ .refs = refs, .tail = tail };
                        if (!supervised) {
                            try refs[i].finish(next);
                            break :again;
                        }
                        const result = refs[i].finish(next);
                        if (slotOf(refs, i).emission.swap(.idle, .acq_rel) == .interrupted) {
                            slotOf(refs, i).finished = true;
                            // Being cancelled was the interruption; anything
                            // else the hook failed with is its own.
                            result catch |err| if (@as(anyerror, err) != error.Canceled) return err;
                            return error.Canceled;
                        }
                        try result;
                        slotOf(refs, i).finished = true;
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

            /// Returns the failure of the stage `who` points to, which is one
            /// of these stages or lies within one of them. Each stage returns
            /// its own error from its own `failure`, so the error set of a run
            /// is inferred like any other and nothing is cast.
            pub fn failureOf(refs: Refs, tail: anytype, who: *const anyopaque) !void {
                inline for (0..n) |i| {
                    const next: Down(@TypeOf(tail), i + 1) = .{ .refs = refs, .tail = tail };
                    if (@hasDecl(stages[i], "failure")) {
                        if (@as(*const anyopaque, @ptrCast(refs[i])) == who) return refs[i].failure(next);
                    }
                    if (@hasDecl(stages[i], "failureOf")) try refs[i].failureOf(next, who);
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
            var state: slots[i] = undefined;
            var next: @Tuple(pointers[0 .. i + 1]) = undefined;
            inline for (0..i) |k| next[k] = partial[k];
            next[i] = if (comptime emitsLate(stages[i])) &state.stage else &state;
            return locals(i + 1, next, body);
        }

        // The same operations for a chain stored as one value. This is what an
        // operator with sub-pipes calls (`branch`, `route`). It is the stage
        // contract except that `start` and `finish` also take the guard: the
        // sub-pipe's `Supervision` (see `Arms`), or `{}` without one.

        fn refsOf(self: *Self) Refs {
            var refs: Refs = undefined;
            inline for (0..n) |i| refs[i] = if (comptime emitsLate(stages[i])) &self.states[i].stage else &self.states[i];
            return refs;
        }

        pub fn init(self: *Self, op: *const Pipe(Ops), env: Env) !void {
            return at.init(self.refsOf(), &op.ops, env);
        }

        pub fn provide(self: *Self, env: Env) types.envs[n] {
            return at.provide(self.refsOf(), env);
        }

        pub fn start(self: *Self, tail: anytype, guard: anytype) !Flow {
            return at.start(self.refsOf(), tail, guard);
        }

        pub fn push(self: *Self, item: In, tail: anytype) !Flow {
            return at.push(self.refsOf(), item, tail);
        }

        pub fn finish(self: *Self, tail: anytype, guard: anytype) !void {
            return at.finish(self.refsOf(), tail, guard);
        }

        pub fn settle(self: *Self, after_is_done: bool) Settled {
            return at.settle(self.refsOf(), after_is_done);
        }

        pub fn flush(self: *Self) !void {
            return at.flush(self.refsOf());
        }

        pub fn failureOf(self: *Self, tail: anytype, who: *const anyopaque) !void {
            return at.failureOf(self.refsOf(), tail, who);
        }

        pub fn stop(self: *Self) void {
            at.stop(self.refsOf());
        }

        pub fn deinit(self: *Self) void {
            at.deinit(self.refsOf());
        }
    };
}
