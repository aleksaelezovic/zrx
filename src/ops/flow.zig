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

                const Self = @This();
                pub const zrx_boundary = {};

                pub fn init(self: *Self, _: *const Op, env: Env) !void {
                    self.io = di.get(env, Io);
                    self.channel = .init(&self.buffer);
                    self.consumer = null;
                    self.ended_with = null;
                    self.supervision = if (comptime di.has(Env, core.Supervision)) di.get(env, core.Supervision) else null;
                    self.ended = false;
                }

                pub fn start(self: *Self, down: anytype) !void {
                    if (self.supervision) |supervision| supervision.adopt(self.io);
                    self.consumer = try self.io.concurrent(Consumer(@TypeOf(down)).run, .{ self, down });
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
                                        self.ended_with = err;
                                        break :consuming .failed;
                                    };
                                    if (flow == .done) break :consuming .satisfied;
                                }
                            };
                            // Unblocks a producer waiting for space; it then sees `.done`.
                            self.channel.close(self.io);
                            // A producer that is not pushing would never look, and a
                            // run joining another worker would not either: tell the run.
                            if (self.supervision) |supervision| {
                                switch (ending) {
                                    .drained => {},
                                    .failed => supervision.fail(self.io, self),
                                    .satisfied => supervision.satisfy(self.io),
                                }
                                supervision.workerEnded(self.io, &self.ended);
                            }
                        }
                    };
                }

                pub fn push(self: *Self, item: In, _: anytype) !Flow {
                    self.channel.putOne(self.io, item) catch |err| switch (err) {
                        error.Closed => return .done,
                        error.Canceled => return error.Canceled,
                    };
                    return .more;
                }

                pub fn finish(self: *Self, down: anytype) !void {
                    self.channel.close(self.io);
                    if (self.consumer) |*consumer| {
                        if (self.supervision) |supervision| {
                            // Wait for this worker to drain, unless another one
                            // fails meanwhile: then the run is over, and `stop`
                            // is what ends this worker.
                            if (!try supervision.awaitWorker(self.io, &self.ended)) return error.Canceled;
                        }
                        consumer.await(self.io);
                        self.consumer = null;
                    }
                    return self.failure(down);
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

                pub fn start(self: *@This(), _: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].start(Closed{});
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    inline for (0..n) |i| {
                        if (self.arms.wants(i)) {
                            if (try self.chains[i].push(item, Closed{}) == .done) self.arms.finished(i);
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
                /// Set when the pipe after the route asked to stop.
                downstream_done: bool,

                const Self = @This();

                pub const has_boundary = anyBoundary(&chains);

                /// The `down` given to a rejoining case: forwards and remembers `.done`.
                ///
                /// Once the pipe after the route is done, nothing is forwarded
                /// to it again, whenever the answer came (a case may emit as
                /// the run starts, as items flow, or as the stream ends):
                /// - every case is marked as wanting no more, which `push`
                ///   already checks before handing a case an item;
                /// - with `at_end`, what a case emits as the stream ends is
                ///   dropped. (Checking the flag itself on every push would
                ///   cost nothing per item but makes the optimizer peel the loop.)
                fn Rejoin(comptime Down: type, comptime at_end: bool) type {
                    return struct {
                        down: Down,
                        route: *Self,

                        pub fn push(self: @This(), item: anytype) !Flow {
                            if (at_end and self.route.downstream_done) return .done;
                            if (try self.down.push(item) == .done) {
                                self.route.downstream_done = true;
                                self.route.arms.finishAll();
                                return .done;
                            }
                            return .more;
                        }
                    };
                }

                fn Tail(comptime Down: type, comptime at_end: bool) type {
                    return if (rejoins) Rejoin(Down, at_end) else Closed;
                }

                fn tail(self: *Self, down: anytype, comptime at_end: bool) Tail(@TypeOf(down), at_end) {
                    return if (rejoins) .{ .down = down, .route = self } else .{};
                }

                pub fn init(self: *Self, op: *const Op, env: Env) !void {
                    self.arms.init(env);
                    self.downstream_done = false;
                    inline for (0..n) |i| {
                        self.tests[i] = if (cases[i].is_otherwise) {} else .init(env);
                        self.chains[i].init(&op.cases[i].pipe, self.arms.envFor(env, i)) catch |err| {
                            inline for (0..i) |j| self.chains[i - 1 - j].deinit();
                            return err;
                        };
                    }
                }

                pub fn start(self: *Self, down: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].start(self.tail(down, false));
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    inline for (0..n) |i| {
                        const taken = if (cases[i].is_otherwise) true else try lift(self.tests[i].call(.{item}));
                        if (taken) {
                            if (self.arms.wants(i)) {
                                if (try self.chains[i].push(item, self.tail(down, false)) == .done) self.arms.finished(i);
                            }
                            return self.verdict();
                        }
                    }
                    return self.verdict();
                }

                fn verdict(self: *const Self) Flow {
                    if (self.downstream_done) return .done;
                    return if (self.arms.anyWants()) .more else .done;
                }

                pub fn finish(self: *Self, down: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].finish(self.tail(down, true), self.arms.guard());
                }

                pub fn flush(self: *Self) !void {
                    inline for (0..n) |i| try self.chains[n - 1 - i].flush();
                }

                pub fn failureOf(self: *Self, down: anytype, who: *const anyopaque) !void {
                    // Only terminating cases can contain a worker.
                    if (rejoins) return;
                    inline for (0..n) |i| try self.chains[i].failureOf(self.tail(down, false), who);
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
