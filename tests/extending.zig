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
const subscribe = zrx.subscribe;

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

            pub fn init(self: *@This(), _: *const Counted, env: Env) !void {
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
    try program(range(u32, 0, 100), pipe(.{ counted(), take(3), subscribe(record) })).run(.{ &seen, &count });
    try seen.expect(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), count);
}

// --- an operator with every optional hook --------------------------------------

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

            pub fn init(self: *@This(), op: *const Echoed, env: Env) !void {
                self.* = .{ .journal = zrx.di.get(env, *Journal), .tail = op.tail };
                self.journal.add('i');
            }

            pub fn start(self: *@This(), _: anytype) !void {
                self.journal.add('s');
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

            pub fn flush(self: *@This()) !void {
                self.journal.add('F');
            }

            pub fn deinit(self: *@This()) void {
                self.journal.add('d');
            }
        };
    }
};

test "stage hooks run in the documented order" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    try program(range(u32, 1, 3), pipe(.{ echoed(9), subscribe(record) })).run(.{ &seen, &journal });
    try seen.expect(&.{ 1, 1, 2, 2, 9 });
    try journal.expect("isppfFd");
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failed run skips finish and flush but not deinit" {
    var seen: Numbers = .{};
    var journal: Journal = .{};
    const result = program(range(u32, 1, 3), pipe(.{ echoed(9), map(failAtTwo), subscribe(record) })).run(.{ &seen, &journal });
    try std.testing.expectError(error.Two, result);
    try journal.expect("isppd");
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
    try program(Powers{ .limit = 40 }, pipe(.{subscribe(record)})).run(.{&seen});
    try program(Powers{ .limit = 1 << 30 }, pipe(.{ take(2), subscribe(record) })).run(.{&seen});
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
    try program(range(u32, 0, 10), pipe(.{ filter(next(withinLimit)), subscribe(record) })).run(.{ &seen, Limit{ .max = 3 } });
    try seen.expect(&.{ 0, 1, 2 });
}
