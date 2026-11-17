//! Flow operators: where a pipe crosses a task boundary or splits.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const completion = @import("../completion.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;
const lift = core.lift;

// ---------------------------------------------------------------------------
// queue
// ---------------------------------------------------------------------------

/// A bounded task boundary. Pass a comptime capacity for stack storage, or
/// a pointer to a mutable fixed-size array to use its slots for the run.
/// Upstream waits when the buffer is full. Needs a `std.Io` dependency.
/// Inline so that a typed comptime capacity can shape the return type
/// while a buffer address can be supplied at runtime.
pub inline fn queue(storage: anytype) (switch (@typeInfo(@TypeOf(storage))) {
    .comptime_int, .int => Queue(queueCapacity(storage), void),
    .pointer => QueueFromBuffer(@TypeOf(storage)),
    else => @compileError("queue: expected a comptime capacity like `queue(32)` or a mutable array pointer like `queue(&slots)`"),
}) {
    return if (@typeInfo(@TypeOf(storage)) == .pointer) .{ .slots = storage } else .{ .slots = {} };
}

fn queueCapacity(comptime capacity: anytype) usize {
    if (capacity < 0 or capacity > std.math.maxInt(usize))
        @compileError("queue: capacity must fit in usize; pass a positive comptime capacity");
    return @intCast(capacity);
}

fn QueueFromBuffer(comptime Pointer: type) type {
    const ptr = @typeInfo(Pointer).pointer;
    if (ptr.size == .one and !ptr.attrs.@"const" and !ptr.attrs.@"volatile" and
        !ptr.attrs.@"allowzero" and @typeInfo(ptr.child) == .array)
    {
        if (std.meta.alignment(Pointer) < @alignOf(ptr.child))
            @compileError("queue: buffer is under-aligned; use a naturally aligned array of the item type");
        const array = @typeInfo(ptr.child).array;
        return Queue(array.len, *[array.len]array.child);
    }
    @compileError("queue: buffer must be a mutable fixed-size array pointer; pass `&slots` for `var slots: [N]T`");
}

fn Queue(comptime capacity: usize, comptime Buffer: type) type {
    if (capacity == 0) @compileError("queue: capacity must be at least 1");
    return struct {
        slots: Buffer,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "queue";

        pub fn Out(comptime Env: type, comptime In: type) type {
            if (!di.has(Env, Io)) @compileError("queue: needs `std.Io` to run its consumer task; pass `io` to `run(.{ io, ... })`");
            if (@sizeOf(In) == 0) @compileError("queue: items of type `" ++ @typeName(In) ++ "` carry no data to buffer");
            if (Buffer != void) {
                const Slot = std.meta.Child(std.meta.Child(Buffer));
                if (Slot != In) @compileError(
                    "queue: buffer holds `" ++ @typeName(Slot) ++ "` but the pipe sends `" ++ @typeName(In) ++
                        "`; declare the slots as `[N]" ++ @typeName(In) ++ "`",
                );
            }
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                io: Io,
                buffer: if (Buffer == void) [capacity]In else void,
                channel: Io.Queue(In),

                const Self = @This();
                pub const zrx_boundary = {};

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.io = di.get(env, Io);
                    self.channel = .init(if (Buffer == void) &self.buffer else op.slots);
                }

                pub fn taskIo(self: *Self) Io {
                    return self.io;
                }

                pub fn push(self: *Self, item: In, _: anytype) !Flow {
                    self.channel.putOne(self.io, item) catch |err| switch (err) {
                        // The far side is done.
                        error.Closed => return .done,
                        error.Canceled => return error.Canceled,
                    };
                    return .more;
                }

                /// No more items will come: the task drains the buffer and
                /// then ends the stream for what follows.
                pub fn finish(self: *Self, _: anytype) !void {
                    self.channel.close(self.io);
                }

                /// The task of the far side. Returns when the near side has
                /// finished and the buffer is empty, or when `down` is done;
                /// fails with what `down` failed with.
                pub fn work(self: *Self, down: anytype) !void {
                    while (true) {
                        const item = self.channel.getOne(self.io) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return error.Canceled,
                        };
                        if (try down.push(item) == .done) return;
                    }
                }

                /// The task is gone, or the run is over: a producer waiting
                /// for space, or pushing later, is answered `.done`, and the
                /// task runs out of input once the buffer is empty. Safe to
                /// call again and from any task.
                pub fn retire(self: *Self) void {
                    self.channel.close(self.io);
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
                live: [n]bool,
                demands: if (tracks_demand) [n]completion.Demand else void,

                pub const has_boundary = core.anyBoundary(@Tuple(&chains));
                const tracks_demand = has_boundary and di.has(Env, completion.Track);

                pub fn Tasks(comptime _: type) type {
                    return core.TasksOf(@Tuple(&chains), Closed);
                }

                pub fn tasks(self: *@This(), down: anytype) Tasks(@TypeOf(down)) {
                    if (tracks_demand) return core.subPipeTasks(&self.chains, Closed{}, down.collector, &self.demands);
                    return core.tasksOf(&self.chains, Closed{});
                }

                pub fn init(self: *@This(), op: *const Op, env: Env) void {
                    self.live = @splat(true);
                    self.demands = if (tracks_demand) @splat(.{}) else {};
                    inline for (0..n) |i| {
                        self.chains[i].init(&op.pipes[i], env);
                    }
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    var wanted = false;
                    inline for (0..n) |i| {
                        if (self.live[i]) {
                            if (try self.chains[i].push(item, Closed{}) == .done) {
                                self.live[i] = false;
                                if (tracks_demand) self.demands[i].complete();
                            } else {
                                wanted = true;
                            }
                        }
                    }
                    return if (wanted) .more else .done;
                }

                pub fn finish(self: *@This(), _: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].finish(Closed{});
                }
            };
        }
    };
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
                    "route: case {d} rejoins the pipe, so it cannot contain a task boundary; put the boundary after the route",
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
                live: [n]bool,
                demands: if (tracks_demand) [n]completion.Demand else void,
                /// The route wants no more items: no case does, or the pipe
                /// after it is done. Kept as one flag because it is asked
                /// ahead of the per-item work, where walking `live` instead
                /// makes the optimizer reshape the loop.
                done: bool,
                /// Set when the pipe after the route asked to stop.
                downstream_done: bool,

                const Self = @This();

                /// The `down` given to a rejoining case: forwards and remembers `.done`.
                ///
                /// Once the pipe after the route is done, nothing is forwarded
                /// to it again, whenever the answer came (a case may emit as
                /// items flow or as the stream ends):
                /// - every case is marked as wanting no more, which `push`
                ///   already checks before handing a case an item;
                /// - with `guarded`, an emission is dropped: that is how cases
                ///   are finished, where each one still runs but what it
                ///   emits must not get past a pipe that is done.
                ///   (Checking the flag itself on every push as well would
                ///   cost nothing per item but makes the optimizer peel the loop.)
                fn Rejoin(comptime Down: type, comptime guarded: bool) type {
                    return struct {
                        down: Down,
                        route: *Self,

                        pub fn push(self: @This(), item: anytype) !Flow {
                            if (guarded and self.route.downstream_done) return .done;
                            if (try self.down.push(item) == .done) {
                                self.route.downstream_done = true;
                                self.route.live = @splat(false);
                                self.route.done = true;
                                return .done;
                            }
                            return .more;
                        }
                    };
                }

                fn Tail(comptime Down: type, comptime guarded: bool) type {
                    return if (rejoins) Rejoin(Down, guarded) else Closed;
                }

                fn tail(self: *Self, down: anytype, comptime guarded: bool) Tail(@TypeOf(down), guarded) {
                    return if (rejoins) .{ .down = down, .route = self } else .{};
                }

                /// Only terminal cases can hold a boundary (see `Out`).
                pub const has_boundary = core.anyBoundary(@Tuple(&chains));
                const tracks_demand = has_boundary and di.has(Env, completion.Track);

                pub fn Tasks(comptime _: type) type {
                    return if (rejoins) @Tuple(&.{}) else core.TasksOf(@Tuple(&chains), Closed);
                }

                pub fn tasks(self: *Self, down: anytype) Tasks(@TypeOf(down)) {
                    if (tracks_demand) return core.subPipeTasks(&self.chains, Closed{}, down.collector, &self.demands);
                    return if (rejoins) .{} else core.tasksOf(&self.chains, Closed{});
                }

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.live = @splat(true);
                    self.demands = if (tracks_demand) @splat(.{}) else {};
                    self.done = false;
                    self.downstream_done = false;
                    inline for (0..n) |i| {
                        self.tests[i] = if (cases[i].is_otherwise) {} else .init(env);
                        self.chains[i].init(&op.cases[i].pipe, env);
                    }
                }

                pub fn push(self: *Self, item: In, down: anytype) !Flow {
                    // A route that is done runs nothing for an item nobody
                    // takes: no predicate is asked, so none can fail or
                    // block the run over it.
                    if (self.done) return .done;
                    inline for (0..n) |i| {
                        const taken = if (cases[i].is_otherwise) true else try lift(self.tests[i].call(.{item}));
                        if (taken) {
                            if (self.live[i]) {
                                if (try self.chains[i].push(item, self.tail(down, false)) == .done) self.caseDone(i);
                            }
                            return self.verdict();
                        }
                    }
                    return .more;
                }

                fn caseDone(self: *Self, comptime i: usize) void {
                    self.live[i] = false;
                    if (tracks_demand) self.demands[i].complete();
                    inline for (0..n) |k| if (self.live[k]) return;
                    self.done = true;
                }

                fn verdict(self: *const Self) Flow {
                    return if (self.done) .done else .more;
                }

                pub fn finish(self: *Self, down: anytype) !void {
                    inline for (0..n) |i| try self.chains[i].finish(self.tail(down, true));
                }
            };
        }
    };
}
