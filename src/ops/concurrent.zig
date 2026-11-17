//! Bounded work sharing with worker-local synchronous pipes.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const completion = @import("../completion.zig");

/// Distributes input among `workers` copies of a synchronous pipe. Workers
/// take turns pushing their output downstream; input order is not preserved.
pub fn concurrent(comptime workers: anytype, sub: anytype) Concurrent(workerCount(workers), core.NormalizedPipe("concurrent", @TypeOf(sub))) {
    return .{ .pipe = core.normalizePipe("concurrent", sub) };
}

fn workerCount(comptime count: anytype) usize {
    @setEvalBranchQuota(di.quota);
    switch (@typeInfo(@TypeOf(count))) {
        .int, .comptime_int => {},
        else => @compileError("concurrent: worker count must be an integer; pass a positive comptime count such as `concurrent(4, .{ ... })`"),
    }
    if (count <= 0 or count > std.math.maxInt(usize))
        @compileError("concurrent: worker count must be positive and fit in usize; pass a positive comptime count such as `concurrent(4, .{ ... })`");
    return @intCast(count);
}

fn Concurrent(comptime count: usize, comptime P: type) type {
    return struct {
        pipe: P,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "concurrent";

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            if (!di.has(Env, Io)) @compileError("concurrent: needs `std.Io` to run its workers; pass `io` to `run(.{ io, ... })`");
            if (@sizeOf(In) == 0) @compileError("concurrent: items of type `" ++ @typeName(In) ++ "` carry no data to buffer");
            const Output = P.Out(Env, In);
            if (P.Stage(Env, In).has_boundary)
                @compileError("concurrent: worker pipe contains a task boundary; keep it synchronous and put task boundaries outside concurrent(...)");
            return Output;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            _ = Out(Env, In);
            const Chain = P.Stage(Env, In);
            return struct {
                io: Io,
                buffer: [count]In,
                input: Io.Queue(In),
                chains: [count]Chain,
                retired: [count]std.atomic.Value(bool),
                /// Workers whose input loops have not retired.
                active: std.atomic.Value(usize),
                /// Successful worker ends still outstanding.
                unfinished: std.atomic.Value(usize),
                stopping: std.atomic.Value(bool),
                finished: Io.Event,
                output_mutex: Io.Mutex,
                demand: if (tracks_demand) ?*completion.Demand else void,

                const Self = @This();
                pub const zrx_boundary = {};
                const tracks_demand = di.has(Env, completion.Track);

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.io = di.get(env, Io);
                    self.input = .init(&self.buffer);
                    self.active = .init(count);
                    self.unfinished = .init(count);
                    self.stopping = .init(false);
                    self.finished = .unset;
                    self.output_mutex = .init;
                    self.demand = if (tracks_demand) null else {};
                    for (&self.retired) |*retired| retired.* = .init(false);
                    for (&self.chains) |*chain| chain.init(&op.pipe, env);
                }

                pub fn taskIo(self: *Self) Io {
                    return self.io;
                }

                pub fn push(self: *Self, item: In, _: anytype) !core.Flow {
                    self.input.putOne(self.io, item) catch |err| switch (err) {
                        error.Closed => return .done,
                        error.Canceled => return error.Canceled,
                    };
                    return .more;
                }

                pub fn finish(self: *Self, _: anytype) !void {
                    self.input.close(self.io);
                }

                pub fn Tasks(comptime Down: type) type {
                    @setEvalBranchQuota(di.quota);
                    return @Tuple(&@as([count]type, @splat(Worker(Down))));
                }

                pub fn tasks(self: *Self, down: anytype) Tasks(@TypeOf(down)) {
                    if (tracks_demand) self.demand = if (down.collector) |collector| collector.owner else null;
                    var members: Tasks(@TypeOf(down)) = undefined;
                    inline for (0..count) |i| members[i] = .{ .pool = self, .index = i, .down = down };
                    return members;
                }

                pub fn work(self: *Self, _: anytype) !void {
                    // A successful last end or scope retirement releases this
                    // wait. Only the former withdraws upstream demand here.
                    try self.finished.wait(self.io);
                    if (tracks_demand) {
                        if (self.unfinished.load(.acquire) == 0) {
                            if (self.demand) |demand| demand.complete();
                        }
                    }
                }

                pub fn retire(self: *Self) void {
                    self.stopInput();
                    self.finished.set(self.io);
                }

                fn stopInput(self: *Self) void {
                    self.stopping.store(true, .release);
                    self.input.close(self.io);
                }

                fn Gate(comptime Down: type) type {
                    return struct {
                        pool: *Self,
                        down: Down,

                        pub fn push(gate: @This(), item: anytype) !core.Flow {
                            const pool = gate.pool;
                            try pool.output_mutex.lock(pool.io);
                            defer pool.output_mutex.unlock(pool.io);
                            if (pool.stopping.load(.acquire)) return .done;
                            if (try gate.down.push(item) == .done) {
                                pool.stopInput();
                                return .done;
                            }
                            return .more;
                        }
                    };
                }

                fn Worker(comptime Down: type) type {
                    return struct {
                        pool: *Self,
                        index: usize,
                        down: Down,

                        pub fn io(worker: @This()) Io {
                            return worker.pool.io;
                        }

                        pub fn run(worker: @This()) !void {
                            const pool = worker.pool;
                            const gate: Gate(Down) = .{ .pool = pool, .down = worker.down };
                            while (!pool.stopping.load(.acquire) and !pool.retired[worker.index].load(.acquire)) {
                                const item = pool.input.getOne(pool.io) catch |err| switch (err) {
                                    error.Closed => return,
                                    error.Canceled => return error.Canceled,
                                };
                                if (pool.stopping.load(.acquire) or pool.retired[worker.index].load(.acquire)) return;
                                if (try pool.chains[worker.index].push(item, gate) == .done) return;
                            }
                        }

                        pub fn retire(worker: @This()) void {
                            const pool = worker.pool;
                            if (!pool.retired[worker.index].swap(true, .acq_rel) and pool.active.fetchSub(1, .acq_rel) == 1)
                                pool.input.close(pool.io);
                        }

                        pub fn end(worker: @This()) !void {
                            const pool = worker.pool;
                            try pool.chains[worker.index].finish(Gate(Down){ .pool = pool, .down = worker.down });
                            if (pool.unfinished.fetchSub(1, .acq_rel) == 1) pool.finished.set(pool.io);
                        }
                    };
                }
            };
        }
    };
}
