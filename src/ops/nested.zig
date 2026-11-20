//! Sub-pipes that run inside one push: `each` runs a fresh one over a source
//! made from every item, and two send a failure down an error path, a
//! sub-pipe of `Failed` items: `attempt` to turn the failure of a sub-pipe
//! into a value, `recover` to take a failed item out of the pipe.
//!
//! None is a task boundary and none may contain one: what the sub-pipe
//! does for an item is over when the push of that item returns.
const std = @import("std");
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const program = @import("../program.zig");
const sources = @import("../sources.zig");
const completion = @import("../completion.zig");
const failure = @import("../failure.zig");
const Failed = failure.Failed;
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;
const lift = core.lift;

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

        /// What `sub` emits for the items of that source.
        fn Emitted(comptime Env: type, comptime In: type) type {
            const Item = Source(Env, In).Item;
            const T = Sub.Out(Env, Item);
            if (T == End) @compileError("each: the sub-pipe ends with a terminal operator, so it emits nothing to pair with the item; remove it and end the pipe after each(...)");
            if (Sub.Stage(Env, Item).has_boundary)
                @compileError("each: the sub-pipe contains a task boundary, but it lives for one item; keep it synchronous and put task boundaries outside each(...)");
            return T;
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = Emitted(Env, In);
            // The item as `source_of` takes it: a pipe written for
            // `[]const u8` then emits the same type whichever kind of
            // slice it is fed.
            return sources.Tagged(di.Param(source_of, 1, 0) orelse In, T);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const S = Source(Env, In);
            const T = Emitted(Env, In);
            const Pair = Out(Env, In);
            const Chain = Sub.Stage(Env, S.Item);
            // As for a program without a task boundary: a producer that asks
            // for `Stop` learns about completion through its pushes.
            const wants_stop = completion.sourceWantsStop(S);
            return struct {
                op: *const Op,
                /// Kept to construct the sub-pipe's stages for every item.
                env: Env,

                const Self = @This();

                /// The `down` of the sub-pipe: pairs what it emits with the
                /// item and notes when the pipe after `each` is done. Only
                /// that ends `each`; a sub-pipe that is done ends its item.
                fn Paired(comptime Down: type) type {
                    return struct {
                        down: Down,
                        of: @FieldType(Pair, "source"),
                        done: *bool,

                        pub fn push(tail: @This(), value: T) !Flow {
                            if (try tail.down.push(Pair{ .source = tail.of, .item = value }) == .done) {
                                tail.done.* = true;
                                return .done;
                            }
                            return .more;
                        }
                    };
                }

                /// The `down` the item's source pushes into.
                fn Feed(comptime Tail: type) type {
                    return struct {
                        chain: *Chain,
                        tail: Tail,

                        pub fn push(feed: @This(), item: S.Item) !Flow {
                            return feed.chain.push(item, feed.tail);
                        }
                    };
                }

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.* = .{ .op = op, .env = env };
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    const source: S = try lift(di.invoke(source_of, self.env, .{item}));
                    var done = false;
                    const tail: Paired(@TypeOf(down)) = .{ .down = down, .of = item, .done = &done };
                    var chain: Chain = undefined;
                    chain.init(&self.op.pipe, self.env);
                    const source_env = if (wants_stop) di.extend(self.env, completion.Stop{}) else self.env;
                    try source.run(source_env, Feed(@TypeOf(tail)){ .chain = &chain, .tail = tail });
                    try chain.finish(tail);
                    return if (done) .done else .more;
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// error paths: attempt and recover
// ---------------------------------------------------------------------------

/// The error set an error path is for, checked where the operator is written.
fn Handled(comptime who: []const u8, comptime example: []const u8, comptime handler: []const u8, comptime handled: anytype) type {
    if (@TypeOf(handled) != type or @typeInfo(handled) != .error_set) @compileError(
        who ++ ": the errors to take must be an error set such as `ParseError`, or `anyerror`, got `" ++
            (if (@TypeOf(handled) == type) @typeName(handled) else @typeName(@TypeOf(handled))) ++
            "`; write `" ++ example ++ "`, where `" ++ handler ++ "` takes a `Failed(ParseError, Item)`",
    );
    // Said where the set is written: what the guarded operators can fail
    // with is not always known, but a set that takes nothing takes nothing.
    if (!failure.takesAny(handled, .passes, anyerror)) @compileError(
        who ++ ": `" ++ @typeName(handled) ++ "` holds no error an error path takes, so its path would never be taken. `error.Canceled` always passes, " ++
            "whatever the set says; name the errors to take, such as `ParseError`, or `anyerror`",
    );
    return handled;
}

/// What stands between a sub-pipe that rejoins and the pipe after it: the
/// `down` the sub-pipe is given. A failure of the pipe after it does not
/// travel back through the sub-pipe, where it would look like the
/// sub-pipe's own and a `recover` in there could take it. It is set aside,
/// the sub-pipe is told that nothing more is wanted, and whoever pushed
/// returns it once the sub-pipe has returned.
///
/// Everything a sub-pipe of `attempt` hands to the pipe after it goes
/// through one of these: what either sub-pipe emits for an item, and what
/// either emits at the end of the stream.
fn Seal(comptime Down: type, comptime T: type) type {
    return struct {
        down: Down,
        failed: ?Outside = null,

        const Sealed = @This();

        /// What a push into `Down` can fail with.
        const Outside = @typeInfo(@TypeOf(@as(Down, undefined).push(@as(T, undefined)))).error_union.error_set;

        const Tail = struct {
            seal: *Sealed,

            pub fn push(end: Tail, value: T) error{}!Flow {
                if (end.seal.failed != null) return .done;
                return end.seal.down.push(value) catch |err| {
                    end.seal.failed = err;
                    return .done;
                };
            }
        };

        fn tail(seal: *Sealed) Tail {
            return .{ .seal = seal };
        }
    };
}

/// `sub`, with a failure turned into a value. When `sub` fails for an item
/// with an error in `handled`, a `Failed(handled, Item)` goes down `path`,
/// with the item as it was at the `attempt`, and what `path` emits takes the
/// place of what `sub` would have. Where `recover` takes a failed item out
/// of the pipe, this keeps it, as whatever the path makes of the failure.
///
/// `handled` selects what the path takes, as it does for `recover`: an error
/// set, or `anyerror`. Every other error of `sub` fails the run, and
/// `error.Canceled` is never taken. The path has stages and state of its own
/// for the whole stream, and is finished after `sub`.
///
/// What `sub` had already emitted for the item is not taken back, and its
/// stages keep the state the item gave them. A failure of the pipe *after*
/// the `attempt` is neither sub-pipe's: it fails the run as it would without
/// the `attempt`, whichever of the two was emitting, for an item or at the
/// end of the stream, and a `recover` inside either does not see it.
pub fn attempt(sub: anytype, comptime handled: anytype, path: anytype) Attempt(
    core.NormalizedPipe("attempt", @TypeOf(sub)),
    Handled("attempt", "attempt(sub, ParseError, .{ map(fallback) })", "fallback", handled),
    ErrorPath(@TypeOf(path)),
) {
    return .{ .pipe = core.normalizePipe("attempt", sub), .path = core.normalizePipe("attempt", path) };
}

/// The type of an `attempt`'s error path. A handler is what stood here before
/// the path did.
fn ErrorPath(comptime Given: type) type {
    if (Given == type or @typeInfo(Given) == .@"fn") @compileError(
        "attempt: the last argument is the error path, a pipe from the failure to what the sub-pipe emits, not a handler; " ++
            "write `attempt(sub, ParseError, .{ map(fallback) })`, where `fallback` takes a `Failed(ParseError, Item)`",
    );
    return core.NormalizedPipe("attempt", Given);
}

fn Attempt(comptime Sub: type, comptime E: type, comptime Path: type) type {
    return struct {
        pipe: Sub,
        path: Path,

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
            if (T == End) @compileError("attempt: the sub-pipe ends with a terminal operator, so it emits nothing an error path could take the place of; remove it and end the pipe after attempt(...)");
            if (Sub.Stage(Env, In).has_boundary)
                @compileError("attempt: the sub-pipe contains a task boundary, and a failure beyond it is not the item's; put the boundary outside attempt(...)");
            return T;
        }

        /// The errors `sub` itself can fail an item with: those of a push
        /// into it when the pipe after it cannot fail.
        fn Failure(comptime Env: type, comptime In: type) type {
            const Chain = Sub.Stage(Env, In);
            const Pushed = @TypeOf(@as(*Chain, undefined).push(@as(In, undefined), Taking(Emitted(Env, In)){}));
            const Own = @typeInfo(Pushed).error_union.error_set;
            if (@typeInfo(Own).error_set.error_names) |names| {
                if (names.len == 0) @compileError("attempt: the sub-pipe cannot fail; there is nothing to fall back from");
                if (!failure.takesAny(E, .passes, Own)) @compileError(
                    "attempt: the sub-pipe cannot fail with an error in `" ++ @typeName(E) ++ "`, so the error path would never be taken; it can fail with `" ++ errorNames(Own) ++ "`",
                );
            }
            return Own;
        }

        /// `Own` as one would write it: an inferred error set has no such name.
        fn errorNames(comptime Own: type) []const u8 {
            const names = @typeInfo(Own).error_set.error_names orelse return "anyerror";
            var text: []const u8 = "error{";
            for (names, 0..) |error_name, i| text = text ++ (if (i == 0) "" else ",") ++ error_name;
            return text ++ "}";
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = Emitted(Env, In);
            _ = Failure(Env, In);
            const R = Path.Out(Env, Failed(E, In));
            if (R == End) @compileError(
                "attempt: the error path ends with a terminal operator, but the item is kept: the path must emit `" ++ @typeName(T) ++
                    "` like the sub-pipe; to take a failed item out of the pipe, use recover(...)",
            );
            if (R != T) @compileError(
                "attempt: the error path must emit `" ++ @typeName(T) ++ "` like the sub-pipe, got `" ++ @typeName(R) ++ "`",
            );
            if (Path.Stage(Env, Failed(E, In)).has_boundary)
                @compileError("attempt: the error path contains a task boundary, and a failure taken beyond it is no longer the item's; keep the path synchronous");
            return T;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = Out(Env, In);
            const Chain = Sub.Stage(Env, In);
            const Fallback = Path.Stage(Env, Failed(E, In));
            return struct {
                chain: Chain,
                fallback: Fallback,

                const Self = @This();

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.chain.init(&op.pipe, env);
                    self.fallback.init(&op.path, env);
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    var seal: Seal(@TypeOf(down), T) = .{ .down = down };
                    const done = if (self.chain.push(item, seal.tail())) |flow| flow == .done else |err| failed: {
                        // The run has failed already, whatever the sub-pipe
                        // made of being told to stop.
                        if (seal.failed != null) break :failed true;
                        switch (failure.take(E, .passes, err)) {
                            .left => |rest| return rest,
                            .taken => |taken| return self.fallBack(.{ .err = taken, .item = item }, down),
                        }
                    };
                    if (seal.failed) |err| return err;
                    return if (done) .done else .more;
                }

                /// The failure goes down the error path, which is sealed
                /// from the pipe after the attempt as the sub-pipe is.
                fn fallBack(self: *Self, failed: Failed(E, In), down: anytype) !Flow {
                    var seal: Seal(@TypeOf(down), T) = .{ .down = down };
                    const done = if (self.fallback.push(failed, seal.tail())) |flow| flow == .done else |err| own: {
                        if (seal.failed != null) break :own true;
                        return err;
                    };
                    if (seal.failed) |err| return err;
                    return if (done) .done else .more;
                }

                /// The end of the stream is not an item: no failure is taken
                /// here. What the two sub-pipes still emit is sealed too.
                pub fn finish(self: *Self, down: anytype) !void {
                    try ended(&self.chain, down);
                    return ended(&self.fallback, down);
                }

                fn ended(chain: anytype, down: anytype) !void {
                    var seal: Seal(@TypeOf(down), T) = .{ .down = down };
                    chain.finish(seal.tail()) catch |err| {
                        if (seal.failed) |outside| return outside;
                        return err;
                    };
                    if (seal.failed) |outside| return outside;
                }
            };
        }
    };
}

/// Guards the operators after it: when one of them fails for an item with an
/// error in `handled`, the item leaves the pipe and `Failed(handled, Item)`
/// goes down `path` instead, a terminated pipe with stages, state and an end
/// of the stream of its own.
///
/// `handled` selects what is taken: an error set such as `ParseError` lets
/// every other error pass, `anyerror` takes everything. `error.Canceled` is
/// never handed to the path. What the path does with a failure decides how
/// it ends: taking it skips the item, answering `.done` (a `take` in the
/// path) ends the stream as it ends anywhere, and an error of the path's
/// own fails the run.
///
/// A value that a stage *before* the `recover` emits at the end of the stream
/// is an item like any other. Errors of a later stage's own `finish`, or
/// beyond a `queue`, are not per-item and fail the run.
pub fn recover(comptime handled: anytype, path: anytype) Recover(
    Handled("recover", "recover(ParseError, .{ forEach(report) })", "report", handled),
    core.NormalizedPipe("recover", @TypeOf(path)),
) {
    return .{ .path = core.normalizePipe("recover", path) };
}

fn Recover(comptime E: type, comptime P: type) type {
    return struct {
        path: P,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "recover";

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const T = P.Out(Env, Failed(E, In));
            if (T != End) @compileError(
                "recover: the error path still emits `" ++ @typeName(T) ++
                    "`, but a failed item has left the pipe; end the path with forEach(...), drain() or another terminal operator",
            );
            if (P.Stage(Env, Failed(E, In)).has_boundary)
                @compileError("recover: the error path contains a task boundary, and a failure taken beyond it is no longer the item's; keep the path synchronous");
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            _ = Out(Env, In);
            const Chain = P.Stage(Env, Failed(E, In));
            return struct {
                chain: Chain,

                const Self = @This();

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.chain.init(&op.path, env);
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    return down.push(item) catch |err| switch (failure.take(E, .passes, err)) {
                        .left => |rest| return rest,
                        // The failure goes down the path. A path that wants
                        // no more ends the stream: nobody is left to take
                        // the next failure.
                        .taken => |taken| {
                            if (try self.chain.push(.{ .err = taken, .item = item }, Closed{}) == .done) return .done;
                            return .more;
                        },
                    };
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    return self.chain.finish(Closed{});
                }
            };
        }
    };
}
