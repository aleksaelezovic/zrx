//! Sub-pipes that run inside one push: `each` runs a fresh one over a source
//! made from every item, `using` runs a fresh one with a resource acquired
//! for the item, and `attempt` turns the failure of one into a value.
//!
//! None is a task boundary and none may contain one: what the sub-pipe does
//! for an item is over when the push of that item returns.
const std = @import("std");
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const program = @import("../program.zig");
const sources = @import("../sources.zig");
const completion = @import("../completion.zig");
const handlers = @import("../handlers.zig");
const Flow = core.Flow;
const End = core.End;
const lift = core.lift;

// ---------------------------------------------------------------------------
// A sub-pipe that lives for one item: what `each` and `using` share
// ---------------------------------------------------------------------------

/// What a sub-pipe that lives for one item emits for items of type `In`.
/// It has to emit something, and it cannot hold a task: its stages are gone
/// when the push of the item returns.
fn EmittedPerItem(comptime who: []const u8, comptime nothing_to: []const u8, comptime Sub: type, comptime Env: type, comptime In: type) type {
    const T = Sub.Out(Env, In);
    if (T == End) @compileError(who ++ ": the sub-pipe ends with a terminal operator, so it emits nothing to " ++ nothing_to ++ "; remove it and end the pipe after " ++ who ++ "(...)");
    if (Sub.Stage(Env, In).has_boundary)
        @compileError(who ++ ": the sub-pipe contains a task boundary, but it lives for one item; keep it synchronous and put task boundaries outside " ++ who ++ "(...)");
    return T;
}

/// The `down` of such a sub-pipe. It notes when the pipe after the operator
/// is done. Only that ends the operator; a sub-pipe that is done ends its
/// item. With a `Pair`, what the sub-pipe emits is paired with the item.
fn ItemTail(comptime Down: type, comptime T: type, comptime Pair: ?type) type {
    return struct {
        down: Down,
        of: if (Pair) |P| @FieldType(P, "source") else void,
        done: *bool,

        pub fn push(tail: @This(), value: T) !Flow {
            const sent = if (Pair) |P| P{ .source = tail.of, .item = value } else value;
            if (try tail.down.push(sent) == .done) {
                tail.done.* = true;
                return .done;
            }
            return .more;
        }
    };
}

/// The life of one item's sub-pipe: its stages are constructed from `env`,
/// `feed.into` gives them their stream, and they are finished. A failure
/// leaves them unfinished, as it does the stages of a program.
fn live(comptime Chain: type, sub: anytype, env: anytype, tail: anytype, feed: anytype) !void {
    var chain: Chain = undefined;
    chain.init(sub, env);
    try feed.into(&chain, tail);
    try chain.finish(tail);
}

// ---------------------------------------------------------------------------
// each
// ---------------------------------------------------------------------------

/// A nested program per item. `source_of(deps..., item)` returns a source; a
/// fresh `sub` is constructed, the source runs into it to its end, and `sub`
/// is finished, all before the push of that item returns. State in `sub`
/// lasts one item: a `fold` there emits once per item.
///
/// What `sub` emits goes on as `Tagged(Item, Emitted)`: `.item` is the value
/// and `.source` the item it came from, of the type `source_of` declares for
/// it (the item's own type when that parameter is `anytype`).
pub fn each(comptime source_of: anytype, sub: anytype) Each(source_of, core.NormalizedPipe("each", @TypeOf(sub))) {
    return .{ .pipe = core.normalizePipe("each", sub) };
}

fn Each(comptime source_of: anytype, comptime Sub: type) type {
    return struct {
        pipe: Sub,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "each";

        /// The source made from one item.
        fn Source(comptime Env: type, comptime In: type) type {
            const R = di.Bound(name, source_of, Env, &.{In}).Return;
            const S = di.Payload(R);
            if (!program.isSource(S)) @compileError("each: `source_of` must return a source such as fileBytes(...), got `" ++ @typeName(R) ++ "`");
            return S;
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = EmittedPerItem(name, "pair with the item", Sub, Env, Source(Env, In).Item);
            // The item as `source_of` takes it: a pipe written for
            // `[]const u8` then emits the same type whichever kind of
            // slice it is fed.
            return sources.Tagged(di.Param(source_of, 1, 0) orelse In, T);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const S = Source(Env, In);
            const Pair = Out(Env, In);
            const T = @FieldType(Pair, "item");
            const Chain = Sub.Stage(Env, S.Item);
            // As for a program without a task boundary: a producer that asks
            // for `Stop` learns about completion through its pushes.
            const wants_stop = completion.sourceWantsStop(S);
            const SourceEnv = if (wants_stop) di.Extend(Env, completion.Stop) else Env;
            return struct {
                op: *const Op,
                /// Kept to construct the sub-pipe's stages for every item.
                env: Env,

                const Self = @This();

                /// The stream of one item: its source, run into the sub-pipe.
                const FromSource = struct {
                    source: *const S,
                    env: SourceEnv,

                    pub fn into(feed: @This(), chain: *Chain, tail: anytype) !void {
                        return feed.source.run(feed.env, Entry(@TypeOf(tail)){ .chain = chain, .tail = tail });
                    }
                };

                /// The `down` the item's source pushes into.
                fn Entry(comptime Down: type) type {
                    return struct {
                        chain: *Chain,
                        tail: Down,

                        pub fn push(entry: @This(), item: S.Item) !Flow {
                            return entry.chain.push(item, entry.tail);
                        }
                    };
                }

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.* = .{ .op = op, .env = env };
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    const source: S = try lift(di.invoke(source_of, self.env, .{item}));
                    var done = false;
                    const tail: ItemTail(@TypeOf(down), T, Pair) = .{ .down = down, .of = item, .done = &done };
                    const source_env = if (wants_stop) di.extend(self.env, completion.Stop{}) else self.env;
                    try live(Chain, &self.op.pipe, self.env, tail, FromSource{ .source = &source, .env = source_env });
                    return if (done) .done else .more;
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// using
// ---------------------------------------------------------------------------

/// A resource per item. For every item, the `acquire(deps..., item)` of
/// `resource(acquire, release)` gives a value; a fresh `sub` is constructed
/// with that value among its dependencies, the item is pushed into it and
/// `sub` is finished; then `release(deps..., value)` runs, also when `sub`
/// or the pipe after it failed. All of it happens before the push of that
/// item returns. What `sub` emits goes on as it is.
pub fn using(scoped: anytype, sub: anytype) Using(Scoped(@TypeOf(scoped)), core.NormalizedPipe("using", @TypeOf(sub))) {
    return .{ .pipe = core.normalizePipe("using", sub) };
}

/// The `resource(acquire, release)` a `using` is given.
fn Scoped(comptime R: type) type {
    if (@typeInfo(R) != .@"struct" or !@hasDecl(R, "zrx_acquire")) @compileError(
        "using: expected `resource(acquire, release)` as its first argument, got `" ++ @typeName(R) ++ "`; it is acquired for every item and released after it",
    );
    return R;
}

fn Using(comptime R: type, comptime Sub: type) type {
    const acquire = R.zrx_acquire;
    const release = R.zrx_release;
    const releases = @TypeOf(release) != @TypeOf(null);
    return struct {
        pipe: Sub,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "using";

        /// What is acquired for one item. The rules are those of a
        /// program's resource, in the same words.
        fn Value(comptime Env: type, comptime In: type) type {
            const V = di.Payload(di.Bound(name, acquire, Env, &.{In}).Return);
            if (V == void) @compileError("resource: acquire must return the value to provide");
            if (releases and di.Bound(name, release, Env, &.{V}).Return != void)
                @compileError("resource: release must return `void`; a release cannot fail");
            return V;
        }

        /// The environment of the sub-pipe: the stage's, with the value.
        fn Inner(comptime Env: type, comptime In: type) type {
            return di.Extend(Env, Value(Env, In));
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            return EmittedPerItem(name, "send on", Sub, Inner(Env, In), In);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const V = Value(Env, In);
            const T = Out(Env, In);
            const Chain = Sub.Stage(Inner(Env, In), In);
            return struct {
                op: *const Op,
                /// Kept to acquire, to release, and to construct the
                /// sub-pipe's stages for every item.
                env: Env,

                const Self = @This();

                /// The stream of one item: the item.
                const TheItem = struct {
                    item: In,

                    pub fn into(feed: @This(), chain: *Chain, tail: anytype) !void {
                        _ = try chain.push(feed.item, tail);
                    }
                };

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.* = .{ .op = op, .env = env };
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    const value: V = try lift(di.invoke(acquire, self.env, .{item}));
                    defer if (releases) di.invoke(release, self.env, .{value});
                    var done = false;
                    const tail: ItemTail(@TypeOf(down), T, null) = .{ .down = down, .of = {}, .done = &done };
                    try live(Chain, &self.op.pipe, di.extend(self.env, value), tail, TheItem{ .item = item });
                    return if (done) .done else .more;
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// attempt
// ---------------------------------------------------------------------------

/// `orElse` for a sub-pipe: when `sub` fails for an item,
/// `fallback(deps..., err, item)` is emitted in its place, with the item as
/// it was at the `attempt`. The rules are `orElse`'s: the fallback returns
/// what `sub` emits, its error parameter takes every error `sub` can fail
/// with, and `error.Canceled` is never handed over.
///
/// What `sub` had already emitted for the item is not taken back, and its
/// stages keep the state the item gave them. A failure of the pipe *after*
/// the `attempt` is not the sub-pipe's: it fails the run as it would without
/// the `attempt`. So does a failure of `sub`'s own end of stream.
pub fn attempt(sub: anytype, comptime fallback: anytype) Attempt(core.NormalizedPipe("attempt", @TypeOf(sub)), fallback) {
    return .{ .pipe = core.normalizePipe("attempt", sub) };
}

fn Attempt(comptime Sub: type, comptime fallback: anytype) type {
    return struct {
        pipe: Sub,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "attempt";

        /// A `down` that takes what `sub` emits and cannot fail.
        fn Taking(comptime T: type) type {
            return struct {
                pub fn push(_: @This(), _: T) error{}!Flow {
                    return .more;
                }
            };
        }

        fn Emitted(comptime Env: type, comptime In: type) type {
            const T = Sub.Out(Env, In);
            if (T == End) @compileError("attempt: the sub-pipe ends with a terminal operator, so there is nothing to emit a fallback in place of; remove it and end the pipe after attempt(...)");
            if (Sub.Stage(Env, In).has_boundary)
                @compileError("attempt: the sub-pipe contains a task boundary, and a failure beyond it is not the item's; put the boundary outside attempt(...)");
            return T;
        }

        /// The errors `sub` itself can fail an item with: those of a push
        /// into it when the pipe after it cannot fail.
        fn Failure(comptime Env: type, comptime In: type) type {
            const Chain = Sub.Stage(Env, In);
            const Pushed = @TypeOf(@as(*Chain, undefined).push(@as(In, undefined), Taking(Emitted(Env, In)){}));
            const E = @typeInfo(Pushed).error_union.error_set;
            if (@typeInfo(E).error_set.error_names) |names| {
                if (names.len == 0) @compileError("attempt: the sub-pipe cannot fail; there is nothing to fall back from");
            }
            return E;
        }

        /// `E` as one would write it: an inferred error set has no such name.
        fn errorNames(comptime E: type) []const u8 {
            const names = @typeInfo(E).error_set.error_names orelse return "anyerror";
            var text: []const u8 = "error{";
            for (names, 0..) |error_name, i| text = text ++ (if (i == 0) "" else ",") ++ error_name;
            return text ++ "}";
        }

        /// The type the fallback's error parameter is given: the one it
        /// declares, or the sub-pipe's whole error set when it is generic.
        fn Given(comptime Env: type, comptime In: type) type {
            if (!di.isHandler(fallback)) @compileError("attempt: expected a fallback `fn (deps..., err, item) T`, got `" ++ @typeName(@TypeOf(fallback)) ++ "`");
            return di.Param(fallback, 2, 0) orelse Failure(Env, In);
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = Emitted(Env, In);
            const E = Failure(Env, In);
            const Takes = Given(Env, In);
            if (!handlers.takesAll(Takes, E)) @compileError(
                "attempt: the fallback takes `" ++ @typeName(Takes) ++ "` but the sub-pipe can fail with `" ++ errorNames(E) ++ "`",
            );
            const R = di.Bound(name, fallback, Env, &.{ Takes, In }).Return;
            if (di.Payload(R) != T) @compileError(
                "attempt: the fallback must return `" ++ @typeName(T) ++ "` like the sub-pipe, got `" ++ @typeName(R) ++ "`",
            );
            return T;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = Out(Env, In);
            const E = Failure(Env, In);
            const Takes = Given(Env, In);
            const Chain = Sub.Stage(Env, In);
            const Rescue = di.Bound(name, fallback, Env, &.{ Takes, In });
            return struct {
                chain: Chain,
                rescue: Rescue,

                const Self = @This();

                /// What a push into `Down` can fail with.
                fn Outside(comptime Down: type) type {
                    return @typeInfo(@TypeOf(@as(Down, undefined).push(@as(T, undefined)))).error_union.error_set;
                }

                /// The `down` of the sub-pipe. A failure of the pipe after
                /// the `attempt` does not travel back through the sub-pipe,
                /// where it would look like the sub-pipe's own: it is put
                /// aside, the sub-pipe is told that nothing more is wanted,
                /// and `push` returns it once the sub-pipe has returned.
                fn Tail(comptime Down: type) type {
                    return struct {
                        down: Down,
                        failed: *?Outside(Down),

                        pub fn push(tail: @This(), value: T) error{}!Flow {
                            if (tail.failed.* != null) return .done;
                            return tail.down.push(value) catch |err| {
                                tail.failed.* = err;
                                return .done;
                            };
                        }
                    };
                }

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.rescue = .init(env);
                    self.chain.init(&op.pipe, env);
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    var outside: ?Outside(@TypeOf(down)) = null;
                    const tail: Tail(@TypeOf(down)) = .{ .down = down, .failed = &outside };
                    const done = if (self.chain.push(item, tail)) |flow| flow == .done else |err| failed: {
                        // The run has failed already, whatever the sub-pipe
                        // made of being told to stop.
                        if (outside != null) break :failed true;
                        if (comptime handlers.canCancel(E)) {
                            if (@as(anyerror, err) == error.Canceled) return error.Canceled;
                        }
                        // A cancellation never gets here, so the error fits the
                        // fallback's parameter even when that leaves `Canceled` out.
                        const given: Takes = if (comptime Takes == E) err else @errorCast(err);
                        return down.push(try lift(self.rescue.call(.{ given, item })));
                    };
                    if (outside) |err| return err;
                    return if (done) .done else .more;
                }

                /// The end of the stream is not an item: nothing is caught here.
                pub fn finish(self: *Self, down: anytype) !void {
                    return self.chain.finish(down);
                }
            };
        }
    };
}
