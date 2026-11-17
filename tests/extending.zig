//! The public contracts for operators, sources and handlers written outside
//! the library. The operator below is the one shown in docs/guide.md.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const forEach = zrx.forEach;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

// --- an operator ------------------------------------------------------------

pub fn counted() Counted {
    return .{};
}

const Counted = struct {
    pub const zrx_operator = {};
    pub const name = "counted";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (!zrx.di.has(Env, *usize)) @compileError("counted: needs a `*usize` dependency");
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            count: *usize,

            pub fn init(self: *@This(), _: *const Counted, env: Env) void {
                self.count = zrx.di.get(env, *usize);
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.count.* += 1;
                return down.push(item);
            }
        };
    }
};

test "a custom operator composes with the built-in ones" {
    var seen: Numbers = .{};
    var count: usize = 0;
    try program(range(u32, 0, 100), pipe(.{ counted(), take(3), forEach(record) })).run(.{ &seen, &count });
    try seen.expect(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), count);
}

// --- an operator with an end-of-stream hook --------------------------------------

const Journal = support.Recorder(u8);

/// Emits each item twice and one extra `tail` item when the stream ends.
fn echoed(tail: u32) Echoed {
    return .{ .tail = tail };
}

const Echoed = struct {
    tail: u32,

    pub const zrx_operator = {};
    pub const name = "echoed";

    pub fn Out(comptime _: type, comptime In: type) type {
        if (In != u32) @compileError("echoed: items must be u32");
        return u32;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            journal: *Journal,
            tail: u32,

            pub fn init(self: *@This(), op: *const Echoed, env: Env) void {
                self.* = .{ .journal = zrx.di.get(env, *Journal), .tail = op.tail };
                self.journal.add('i');
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.journal.add('p');
                if (try down.push(item) == .done) return .done;
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                self.journal.add('f');
                _ = try down.push(self.tail);
            }
        };
    }
};

test "stage hooks run in the documented order" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    try program(range(u32, 1, 3), pipe(.{ echoed(9), forEach(record) })).run(.{ &seen, &journal });
    try seen.expect(&.{ 1, 1, 2, 2, 9 });
    try journal.expect("ippf");
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failed synchronous run skips finish" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    const result = program(range(u32, 1, 3), pipe(.{ echoed(9), map(failAtTwo), forEach(record) })).run(.{ &seen, &journal });
    try std.testing.expectError(error.Two, result);
    try journal.expect("ipp");
}

// --- a source -----------------------------------------------------------------

/// Powers of two below `limit`.
const Powers = struct {
    limit: u32,

    pub const zrx_source = {};
    pub const Item = u32;

    pub fn run(self: *const Powers, _: anytype, down: anytype) !void {
        var value: u32 = 1;
        while (value < self.limit) : (value *= 2) {
            if (try down.push(value) == .done) return;
        }
    }
};

test "a custom source" {
    var seen: Numbers = .{};
    try program(Powers{ .limit = 40 }, pipe(.{forEach(record)})).run(.{&seen});
    try program(Powers{ .limit = 1 << 30 }, pipe(.{ take(2), forEach(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2, 4, 8, 16, 32, 1, 2 });
}

// --- a composite handler ---------------------------------------------------------

/// A predicate that is true when `predicate` is true for the item plus one.
fn next(comptime predicate: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return zrx.di.requires("next", predicate, arity);
        }

        pub fn call(env: anytype, args: anytype) bool {
            return zrx.di.invoke(predicate, env, .{args[0] + 1});
        }
    };
}

const Limit = struct { max: u32 };
fn withinLimit(limit: Limit, value: u32) bool {
    return value <= limit.max;
}

test "a custom composite handler forwards dependencies" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 10), pipe(.{ filter(next(withinLimit)), forEach(record) })).run(.{ &seen, Limit{ .max = 3 } });
    try seen.expect(&.{ 0, 1, 2 });
}

// --- a task boundary of your own -------------------------------------------------

test "a boundary written against the contract splits the pipe like a queue" {
    var seen: Numbers = .{};
    const io = std.testing.io;
    try program(range(u32, 0, 20), pipe(.{ support.handoff(2), zrx.fold(@as(u32, 0), sumUp), forEach(record) })).run(.{ io, &seen });
    try seen.expect(&.{190});

    var taken: Numbers = .{};
    try program(range(u32, 0, std.math.maxInt(u32)), pipe(.{ support.handoff(2), zrx.take(3), forEach(record) })).run(.{ io, &taken });
    try taken.expect(&.{ 0, 1, 2 });

    var failed: Numbers = .{};
    const result = program(range(u32, 0, 20), pipe(.{ support.handoff(2), zrx.map(failAtTwo), forEach(record) })).run(.{ io, &failed });
    try std.testing.expectError(error.Two, result);
    try failed.expect(&.{ 0, 1 });
}

fn sumUp(sum: u32, value: u32) u32 {
    return sum + value;
}

/// An auxiliary task transforms input; the boundary's task delivers output
/// and ends the continuation. Both use only the public task contracts.
const BoundaryIo = struct { io: std.Io };

const Assisted = struct {
    pub const zrx_operator = {};
    pub const name = "assisted";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            io: std.Io,
            incoming: std.Io.Queue(In),
            outgoing: std.Io.Queue(In),
            in_slot: [1]In,
            out_slot: [1]In,

            const Self = @This();
            pub const zrx_boundary = {};

            pub fn init(self: *Self, _: *const Assisted, env: Env) void {
                self.io = if (comptime zrx.di.has(Env, BoundaryIo)) zrx.di.get(env, BoundaryIo).io else zrx.di.get(env, std.Io);
                self.incoming = .init(&self.in_slot);
                self.outgoing = .init(&self.out_slot);
            }
            pub fn taskIo(self: *Self) std.Io {
                return self.io;
            }
            pub fn push(self: *Self, item: In, _: anytype) !zrx.Flow {
                self.incoming.putOne(self.io, item) catch |err| switch (err) {
                    error.Closed => return .done,
                    error.Canceled => return error.Canceled,
                };
                return .more;
            }
            pub fn finish(self: *Self, _: anytype) !void {
                self.incoming.close(self.io);
            }
            pub fn work(self: *Self, down: anytype) !void {
                while (true) {
                    const item = self.outgoing.getOne(self.io) catch |err| switch (err) {
                        error.Closed => return,
                        error.Canceled => return error.Canceled,
                    };
                    if (try down.push(item) == .done) return;
                }
            }
            pub fn retire(self: *Self) void {
                self.incoming.close(self.io);
                self.outgoing.close(self.io);
            }
            pub fn Tasks(comptime _: type) type {
                return struct { Worker };
            }
            pub fn tasks(self: *Self, down: anytype) Tasks(@TypeOf(down)) {
                return .{.{ .stage = self }};
            }

            const Worker = struct {
                stage: *Self,

                pub fn io(worker: @This()) std.Io {
                    return worker.stage.io;
                }

                pub fn run(worker: @This()) !void {
                    const self = worker.stage;
                    while (true) {
                        const item = self.incoming.getOne(self.io) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return error.Canceled,
                        };
                        self.outgoing.putOne(self.io, item + 1) catch |err| switch (err) {
                            error.Closed => return,
                            error.Canceled => return error.Canceled,
                        };
                    }
                }
                pub fn retire(worker: @This()) void {
                    worker.stage.retire();
                }
            };
        };
    }
};

test "a boundary registers auxiliary tasks with the existing task hooks" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 3), .{ Assisted{}, forEach(record) }).run(.{ std.testing.io, &seen });
    try seen.expect(&.{ 1, 2, 3 });
}

test "concurrent workers use their own Io after a boundary with another Io" {
    var seen: Numbers = .{};
    const alternate = support.TaskStarts.over(std.testing.io);
    try program(range(u32, 0, 3), .{
        Assisted{},
        zrx.concurrent(2, .{zrx.take(100)}),
        forEach(record),
    }).run(.{ std.testing.io, BoundaryIo{ .io = alternate }, &seen });
    try std.testing.expectEqual(@as(usize, 3), support.TaskStarts.count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 3), seen.len);
    var sum: u32 = 0;
    for (seen.slice()) |item| sum += item;
    try std.testing.expectEqual(@as(u32, 6), sum);
}
