//! Flow operators: where a pipe crosses a task boundary or splits.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;
const lift = core.lift;

// ---------------------------------------------------------------------------
// queue
// ---------------------------------------------------------------------------

/// A backpressure boundary. Upstream pushes into a bounded buffer of
/// `capacity` items and waits when it is full; a separate task feeds
/// everything after the queue. Needs `std.Io` among the dependencies.
pub fn queue(comptime capacity: usize) Queue(capacity) {
    return .{};
}

fn Queue(comptime capacity: usize) type {
    if (capacity == 0) @compileError("queue: capacity must be at least 1");
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "queue";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (!di.has(Env, Io)) @compileError("queue: needs `std.Io` to run its consumer task; pass `io` to `run(.{ io, ... })`");
            if (@sizeOf(In) == 0) @compileError("queue: items of type `" ++ @typeName(In) ++ "` carry no data to buffer");
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                io: Io,
                buffer: [capacity]In,
                channel: Io.Queue(In),
                consumer: ?Io.Future(void),
                /// The error that stopped the consumer. Written by the
                /// consumer before it reports or ends; read after that.
                ended_with: ?anyerror,
                supervision: ?core.Supervision,
                /// The consumer has returned. Guarded by the supervision.
                ended: bool,
                /// The far side wants no more: the consumer was answered
                /// `.done`. Set by the consumer, read from any task.
                satisfied: std.atomic.Value(bool),
                /// Something after this queue takes no more (`settle`), so
                /// what its worker is doing is for nothing. Read from any task.
                released: std.atomic.Value(bool),

                const Self = @This();
                pub const zrx_boundary = {};

                pub fn init(self: *Self, _: *const Op, env: Env) !void {
                    self.io = di.get(env, Io);
                    self.channel = .init(&self.buffer);
                    self.consumer = null;
                    self.ended_with = null;
                    self.supervision = if (comptime di.has(Env, core.Supervision)) di.get(env, core.Supervision) else null;
                    self.ended = false;
                    self.satisfied = .init(false);
                    self.released = .init(false);
                    if (self.supervision) |supervision| supervision.adopt(self.io);
                }

                pub fn start(self: *Self, down: anytype) !Flow {
                    self.consumer = try self.io.concurrent(Consumer(@TypeOf(down)).run, .{ self, down });
                    return .more;
                }

                fn Consumer(comptime Down: type) type {
                    return struct {
                        fn run(self: *Self, down: Down) void {
                            // Take whatever is ready in one go rather than one lock per item.
                            var ready: [@min(capacity, 32)]In = undefined;
                            const ending: enum { drained, failed, satisfied } = consuming: while (true) {
                                // Closed: upstream ended and the buffer is empty. Canceled: stopped.
                                const count = self.channel.get(self.io, &ready, 1) catch break .drained;
                                for (ready[0..count]) |item| {
                                    const flow = down.push(item) catch |err| {
                                        // Let go of: whatever the handlers
                                        // made of being interrupted, it was
                                        // for an item nobody takes.
                                        if (self.released.load(.acquire)) break :consuming .drained;
                                        self.ended_with = err;
                                        break :consuming .failed;
                                    };
                                    if (flow == .done) break :consuming .satisfied;
                                }
                            };
                            if (ending == .satisfied) self.satisfied.store(true, .release);
                            // Tell the run first, then wake the producer. A producer
                            // that is not pushing would never look; one that is must
                            // not get to answer for the closed queue before the reason
                            // it closed is on record.
                            if (self.supervision) |supervision| switch (ending) {
                                .drained => {},
                                .failed => supervision.fail(self.io, self),
                                .satisfied => supervision.satisfy(self.io),
                            };
                            // Unblocks a producer waiting for space; it then sees `.done`.
                            self.channel.close(self.io);
                            if (self.supervision) |supervision| supervision.workerEnded(self.io, &self.ended);
                        }
                    };
                }

                pub fn push(self: *Self, item: In, _: anytype) !Flow {
                    // Never started: the pipe was done before startup got
                    // here. With no consumer, an item put in the buffer would
                    // stay there, and the next one would wait for space forever.
                    if (self.consumer == null) return .done;
                    self.channel.putOne(self.io, item) catch |err| switch (err) {
                        error.Closed => return .done,
                        error.Canceled => return error.Canceled,
                    };
                    return .more;
                }

                pub fn finish(self: *Self, down: anytype) !void {
                    self.channel.close(self.io);
                    if (self.consumer) |*consumer| {
                        const awaited: core.Supervision.Awaited = if (self.supervision) |supervision|
                            try supervision.awaitWorker(self.io, &self.ended, &self.released)
                        else
                            .ended;
                        switch (awaited) {
                            // Drained.
                            .ended => consumer.await(self.io),
                            // What follows this queue takes no more: the
                            // worker is not waited for, however long the
                            // handler it is in would take.
                            .released => consumer.cancel(self.io),
                            // Another worker failed: the run is over, and
                            // `stop` is what ends this one.
                            .failed_elsewhere => return error.Canceled,
                        }
                        self.consumer = null;
                    }
                    return self.failure(down);
                }

                /// Whether the far side wants no more, or what follows it
                /// takes none: an item put in would be for nothing.
                pub fn takesNoMore(self: *Self) bool {
                    return self.satisfied.load(.acquire) or self.released.load(.acquire);
                }

                /// When something after this queue takes no more: a producer
                /// waiting for space is answered `.done`, and the worker,
                /// which may be stuck in a handler, is let go of (`finish`
                /// will not wait for it).
                pub fn settle(self: *Self, after_is_done: bool) bool {
                    if (!after_is_done) return false;
                    if (self.released.swap(true, .acq_rel)) return false;
                    self.channel.close(self.io);
                    return false;
                }

                /// The error the consumer ended with, if it failed: one that
                /// `down.push` returned, so it is returned as such.
                pub fn failure(self: *Self, down: anytype) !void {
                    const Failure = @typeInfo(@TypeOf(down.push(@as(In, undefined)))).error_union.error_set;
                    const err = self.ended_with orelse return;
                    // (`anyerror` has no list of names; it can hold anything.)
                    const names = comptime @typeInfo(Failure).error_set.error_names;
                    if (comptime names != null and names.?.len == 0) unreachable;
                    return @as(Failure, @errorCast(err));
                }

                /// After a failure the consumer may still be running handlers
                /// of the stages after this one: it must be gone before any of
                /// them is torn down.
                pub fn stop(self: *Self) void {
                    if (self.consumer) |*consumer| {
                        self.channel.close(self.io);
                        consumer.cancel(self.io);
                        self.consumer = null;
                    }
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// branch
// ---------------------------------------------------------------------------

/// Ends the pipe by handing every item to each sub-pipe, in order, by direct
/// call. Every sub-pipe must terminate. Start a sub-pipe with `queue(n)` to
/// run it concurrently with its siblings.
pub fn branch(pipes: anytype) Branch(Pipes("branch", @TypeOf(pipes))) {
    var out: Pipes("branch", @TypeOf(pipes)) = undefined;
    inline for (0..pipes.len) |i| out[i] = pipes[i];
    return .{ .pipes = out };
}

fn Pipes(comptime who: []const u8, comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(Given)) @compileError(who ++ ": expected a tuple of pipes `.{ pipe(...), pipe(...) }`, got `" ++ @typeName(Given) ++ "`");
    const list = di.types(Given);
    if (list.len == 0) @compileError(who ++ ": needs at least one sub-pipe");
    for (list) |P| core.expectPipe(who, P);
    return @Tuple(list);
}

fn Branch(comptime Ps: type) type {
    const pipes = di.types(Ps);
    const n = pipes.len;
    return struct {
        pipes: Ps,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "branch";

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            for (pipes, 0..) |P, i| {
                const T = P.Out(Env, In);
                if (T != End) @compileError(std.fmt.comptimePrint(
                    "branch: sub-pipe {d} still emits `{s}`; every branch must end with a terminal operator such as subscribe(...) or drain()",
                    .{ i, @typeName(T) },
                ));
            }
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const chains = blk: {
                var list: [n]type = undefined;
                for (pipes, 0..) |P, i| list[i] = P.Stage(Env, In);
                break :blk list;
            };
            return struct {
                chains: @Tuple(&chains),
                arms: core.Arms(n, Env),

                pub const has_boundary = anyBoundary(&chains);

                pub fn init(self: *@This(), op: *const Op, env: Env) !void {
                    self.arms.init(env);
                    inline for (0..n) |i| {
                        self.chains[i].init(&op.pipes[i], self.arms.envFor(env, i)) catch |err| {
                            inline for (0..i) |j| self.chains[i - 1 - j].deinit();
                            return err;
                        };
                    }
                }

                pub fn start(self: *@This(), _: anytype) !Flow {
                    inline for (0..n) |i| {
                        const answer = self.chains[i].start(Closed{}, self.arms.guardOf(i)) catch |err| unwanted: {
                            if (!self.arms.moot(i, err)) return err;
                            break :unwanted Flow.done;
                        };
                        if (answer == .done) {
                            self.arms.finished(i);
                            // Only a sub-pipe that has been started can be
                            // done, so if none wants an item, all were.
                            if (!self.arms.anyWants()) return .done;
                        }
                    }
                    return .more;
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    inline for (0..n) |i| {
                        if (self.arms.wants(i)) {
                            // A failure over an item that the sub-pipe, by
                            // a worker's word, no longer wants is not the
                            // run's failure.
                            const flow = self.chains[i].push(item, Closed{}) catch |err| unwanted: {
                                if (!self.arms.moot(i, err)) return err;
                                break :unwanted Flow.done;
                            };
                            if (flow == .done) self.arms.finished(i);
                        }
                    }
                    // Asked after every sub-pipe has had the item, not summed
                    // up along the way: a queued sub-pipe can become done
                    // while a later one is still working on this item.
                    return if (self.arms.anyWants()) .more else .done;
                }

                pub fn failureOf(self: *@This(), _: anytype, who: *const anyopaque) !void {
                    inline for (0..n) |i| try self.chains[i].failureOf(Closed{}, who);
                }

                pub fn takesNoMore(self: *@This()) bool {
                    return !self.arms.anyWants();
                }

                /// Nothing follows a branch, so `after_is_done` is only ever
                /// true when the run is over and lets go of everything:
                /// then no sub-pipe takes another item, with or without a
                /// queue of its own to say so.
                pub fn settle(self: *@This(), after_is_done: bool) bool {
                    if (after_is_done) self.arms.finishAll();
                    var interrupted = false;
                    inline for (0..n) |i| {
                        if (self.chains[i].settle(after_is_done).interrupted) interrupted = true;
                    }
                    return interrupted;
                }

                pub fn finish(self: *@This(), _: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].finish(Closed{}, self.arms.guard());
                }

                pub fn flush(self: *@This()) !void {
                    inline for (0..n) |i| try self.chains[n - 1 - i].flush();
                }

                pub fn stop(self: *@This()) void {
                    inline for (0..n) |i| self.chains[i].stop();
                }

                pub fn deinit(self: *@This()) void {
                    inline for (0..n) |i| self.chains[n - 1 - i].deinit();
                }
            };
        }
    };
}

/// Whether any of the sub-pipe stage types runs part of itself on another task.
fn anyBoundary(comptime chains: []const type) bool {
    for (chains) |C| if (C.has_boundary) return true;
    return false;
}

// ---------------------------------------------------------------------------
// route
// ---------------------------------------------------------------------------

/// A `route` case: items for which `predicate(deps..., item)` is true go to `sub`.
pub fn when(comptime predicate: anytype, sub: anytype) Case("when", predicate, @TypeOf(sub)) {
    return .{ .pipe = sub };
}

/// The final `route` case: items no earlier case took go to `sub`.
pub fn otherwise(sub: anytype) Case("otherwise", null, @TypeOf(sub)) {
    return .{ .pipe = sub };
}

fn Case(comptime who: []const u8, comptime case_predicate: anytype, comptime P: type) type {
    core.expectPipe(who, P);
    return struct {
        pipe: P,

        pub const zrx_case = {};
        pub const predicate = case_predicate;
        pub const is_otherwise = @TypeOf(case_predicate) == @TypeOf(null);
        pub const Sub = P;
    };
}

/// Sends each item to the first case that takes it; an item no case takes is
/// dropped. Either every case terminates (and so does the route), or every
/// case emits the same item type and the pipe continues after the route.
pub fn route(cases: anytype) Route(Cases(@TypeOf(cases))) {
    var out: Cases(@TypeOf(cases)) = undefined;
    inline for (0..cases.len) |i| out[i] = cases[i];
    return .{ .cases = out };
}

fn Cases(comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(Given)) @compileError("route: expected a tuple of cases `.{ when(...), otherwise(...) }`, got `" ++ @typeName(Given) ++ "`");
    const list = di.types(Given);
    if (list.len == 0) @compileError("route: needs at least one case");
    for (list, 0..) |C, i| {
        if (@typeInfo(C) != .@"struct" or !@hasDecl(C, "zrx_case")) @compileError(std.fmt.comptimePrint(
            "route: element {d} is not a case (got `{s}`); use when(predicate, pipe(...)) or otherwise(pipe(...))",
            .{ i, @typeName(C) },
        ));
        if (C.is_otherwise and i + 1 != list.len) @compileError("route: otherwise(...) must be the last case");
    }
    return @Tuple(list);
}

fn Route(comptime Cs: type) type {
    const cases = di.types(Cs);
    const n = cases.len;
    return struct {
        cases: Cs,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "route";

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const First = cases[0].Sub.Out(Env, In);
            for (cases, 0..) |C, i| {
                if (!C.is_otherwise)
                    expectBool(di.Bound("when", C.predicate, Env, &.{In}).Return);
                const T = C.Sub.Out(Env, In);
                if (T != First) @compileError(std.fmt.comptimePrint(
                    "route: every case must end the same way (all terminate, or all emit one item type); case 0 {s} but case {d} {s}",
                    .{ ending(First), i, ending(T) },
                ));
                if (T != End and C.Sub.Stage(Env, In).has_boundary) @compileError(std.fmt.comptimePrint(
                    "route: case {d} rejoins the pipe, so it cannot contain a queue; put the queue after the route",
                    .{i},
                ));
            }
            return First;
        }

        fn expectBool(comptime R: type) void {
            if (di.Payload(R) != bool) @compileError("when: predicate must return `bool` or `E!bool`, got `" ++ @typeName(R) ++ "`");
        }

        fn ending(comptime T: type) []const u8 {
            return if (T == End) "terminates" else "emits `" ++ @typeName(T) ++ "`";
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            const rejoins = Out(Env, In) != End;
            const chains = blk: {
                var list: [n]type = undefined;
                for (cases, 0..) |C, i| list[i] = C.Sub.Stage(Env, In);
                break :blk list;
            };
            const tests = blk: {
                var list: [n]type = undefined;
                for (cases, 0..) |C, i| list[i] = if (C.is_otherwise) void else di.Bound("when", C.predicate, Env, &.{In});
                break :blk list;
            };
            return struct {
                chains: @Tuple(&chains),
                tests: @Tuple(&tests),
                arms: core.Arms(n, Env),
                /// The pipe after the route is done. Set wherever the route
                /// finds out (`closeOutput`) and never unset: the `down` it
                /// is given may differ from hook to hook, and one that
                /// cannot be asked must not make it forget.
                output_done: bool,

                const Self = @This();

                pub const has_boundary = anyBoundary(&chains);

                /// The `down` given to a rejoining case. When the pipe after
                /// the route answers `.done`, every case is marked as wanting
                /// no more, so the route is done as well, and the answer is
                /// remembered: a case's chain asks (`isDone`) before it emits
                /// as the run starts or the stream ends, so nothing reaches
                /// that pipe again and no stage of a case runs for a value
                /// that would get nowhere.
                fn Rejoin(comptime Down: type) type {
                    return struct {
                        down: Down,
                        route: *Self,

                        pub const zrx_answers_done = {};

                        pub fn push(self: @This(), item: anytype) !Flow {
                            // A `down` that can say it is done is asked
                            // before every value: a case may emit several
                            // for one item. (The chain's own handle for
                            // items cannot, and answers the push.)
                            if (comptime core.answersDone(Down)) {
                                if (self.isDone()) return .done;
                            }
                            if (try self.down.push(item) == .done) {
                                self.route.closeOutput();
                                return .done;
                            }
                            return .more;
                        }

                        /// Whether the pipe after the route is done: the route
                        /// already knows, or `down` says so now (the chain's
                        /// handle for starting and finishing can, also for an
                        /// answer given to something that did not come
                        /// through a case). A `down` that cannot be asked is
                        /// anything with a `push`.
                        pub fn isDone(self: @This()) bool {
                            if (self.route.output_done) return true;
                            if (comptime !core.answersDone(Down)) return false;
                            if (!self.down.isDone()) return false;
                            self.route.closeOutput();
                            return true;
                        }
                    };
                }

                fn Tail(comptime Down: type) type {
                    return if (rejoins) Rejoin(Down) else Closed;
                }

                fn tail(self: *Self, down: anytype) Tail(@TypeOf(down)) {
                    return if (rejoins) .{ .down = down, .route = self } else .{};
                }

                pub fn init(self: *Self, op: *const Op, env: Env) !void {
                    self.arms.init(env);
                    self.output_done = false;
                    inline for (0..n) |i| {
                        self.tests[i] = if (cases[i].is_otherwise) {} else .init(env);
                        self.chains[i].init(&op.cases[i].pipe, self.arms.envFor(env, i)) catch |err| {
                            inline for (0..i) |j| self.chains[i - 1 - j].deinit();
                            return err;
                        };
                    }
                }

                pub fn start(self: *Self, down: anytype) !Flow {
                    inline for (0..n) |i| {
                        // Once the pipe after the route is done, no case is
                        // started: nothing it emitted would get anywhere,
                        // and its hook could block or fail. Asked before
                        // each case, because an emission can be refused
                        // without anything being pushed, and that looks
                        // like the case being done by itself.
                        if (self.outputIsDone(down)) return .done;
                        // A case that is done by itself leaves the others to
                        // start. (A worker's word that the pipe wants no
                        // more needs nothing here: each case's own guard
                        // looks at every pipe the case lies in.)
                        const answer = self.chains[i].start(self.tail(down), self.arms.guardOf(i)) catch |err| unwanted: {
                            if (!self.arms.moot(i, err)) return err;
                            break :unwanted Flow.done;
                        };
                        if (answer == .done) self.arms.finished(i);
                    }
                    return if (self.outputIsDone(down)) .done else self.verdict();
                }

                /// Whether the pipe after the route is done, asking `down`
                /// if it can say.
                fn outputIsDone(self: *Self, down: anytype) bool {
                    if (!rejoins) return false;
                    return self.tail(down).isDone();
                }

                /// The pipe after the route is done, however that became
                /// known: then so is every case, and the route.
                fn closeOutput(self: *Self) void {
                    self.output_done = true;
                    self.arms.finishAll();
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    // A route that is done runs nothing for an item nobody
                    // takes: no predicate is asked, so none can fail or
                    // block the run over it.
                    if (self.verdict() == .done) return .done;
                    // A `down` that can say it is done is asked before
                    // anything runs for the item. (The chain's own handle
                    // for items cannot: there, done is the answer to a push.)
                    if (comptime rejoins and core.answersDone(@TypeOf(down))) {
                        if (self.outputIsDone(down)) return .done;
                    }
                    inline for (0..n) |i| {
                        const taken = if (cases[i].is_otherwise) true else try lift(self.tests[i].call(.{item}));
                        if (taken) {
                            if (self.arms.wants(i)) {
                                // A failure over an item that the case, by a
                                // worker's word, no longer wants is not the
                                // run's failure. (A predicate's needs nothing
                                // here: if every case is done, so is the pipe
                                // the route ends, and whoever pushed into
                                // that pipe sees it.)
                                const flow = self.chains[i].push(item, self.tail(down)) catch |err| unwanted: {
                                    if (!self.arms.moot(i, err)) return err;
                                    break :unwanted Flow.done;
                                };
                                if (flow == .done) self.arms.finished(i);
                            }
                            return self.verdict();
                        }
                    }
                    return self.verdict();
                }

                /// When the pipe after the route is done, so is every case
                /// (`Rejoin`), which makes this the one question to ask.
                fn verdict(self: *const Self) Flow {
                    return if (self.arms.anyWants()) .more else .done;
                }

                pub fn finish(self: *Self, down: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].finish(self.tail(down), self.arms.guard());
                }

                pub fn flush(self: *Self) !void {
                    inline for (0..n) |i| try self.chains[n - 1 - i].flush();
                }

                pub fn takesNoMore(self: *Self) bool {
                    return !self.arms.anyWants();
                }

                /// What follows a rejoining case is what follows the route.
                /// Nothing follows a case that ends there: for it,
                /// `after_is_done` is only ever true when the run is over.
                /// Either way no case takes another item then.
                pub fn settle(self: *Self, after_is_done: bool) bool {
                    if (after_is_done) self.arms.finishAll();
                    var interrupted = false;
                    inline for (0..n) |i| {
                        if (self.chains[i].settle(after_is_done).interrupted) interrupted = true;
                    }
                    return interrupted;
                }

                pub fn failureOf(self: *Self, down: anytype, who: *const anyopaque) !void {
                    // Only terminating cases can contain a worker.
                    if (rejoins) return;
                    inline for (0..n) |i| try self.chains[i].failureOf(self.tail(down), who);
                }

                pub fn stop(self: *Self) void {
                    inline for (0..n) |i| self.chains[i].stop();
                }

                pub fn deinit(self: *Self) void {
                    inline for (0..n) |i| self.chains[n - 1 - i].deinit();
                }
            };
        }
    };
}
