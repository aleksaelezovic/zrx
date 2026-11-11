//! queue, branch and route.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const fold = zrx.fold;
const take = zrx.take;
const queue = zrx.queue;
const branch = zrx.branch;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const provide = zrx.provide;
const subscribe = zrx.subscribe;
const drain = zrx.drain;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

fn double(value: u32) u32 {
    return value * 2;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn add(sum: u32, value: u32) u32 {
    return sum + value;
}

// --- queue ----------------------------------------------------------------

test "a queue delivers every item in order" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 100), pipe(.{ map(double), queue(8), filter(isEven), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 100), seen.len);
    for (seen.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i * 2)), value);
}

fn slowly(clock: std.Io, value: u32) !u32 {
    try clock.sleep(.fromMicroseconds(200), .awake);
    return value;
}

test "a full queue makes the producer wait instead of dropping items" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 40), pipe(.{ queue(1), map(slowly), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectEqual(@as(usize, 40), seen.len);
    for (seen.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
}

test "the stream end waits for the queue to drain, then finishes what follows it" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 101), pipe(.{ queue(4), fold(@as(u32, 0), add), subscribe(record) })).run(.{ io, &seen });
    try seen.expect(&.{5050});
}

fn failAtFive(value: u32) error{Five}!u32 {
    if (value == 5) return error.Five;
    return value;
}

test "an error after a queue fails the run" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 1000), pipe(.{ queue(2), map(failAtFive), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

test "an error before a queue stops its consumer" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 1000), pipe(.{ map(failAtFive), queue(2), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try std.testing.expect(seen.len <= 5);
}

test "take after a queue stops an endless source" {
    var seen: Numbers = .{};
    try program(range(u32, 0, std.math.maxInt(u32)), pipe(.{ queue(4), take(3), subscribe(record) })).run(.{ io, &seen });
    try seen.expect(&.{ 0, 1, 2 });
}

test "queues compose: two boundaries in one pipe" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 50), pipe(.{ queue(2), map(double), queue(2), fold(@as(u32, 0), add), subscribe(record) })).run(.{ io, &seen });
    try seen.expect(&.{2450});
}

// --- branch ---------------------------------------------------------------

const Left = struct { seen: *Numbers };
const Right = struct { seen: *Numbers };
fn toLeft(sink: Left, value: u32) void {
    sink.seen.add(value);
}
fn toRight(sink: Right, value: u32) void {
    sink.seen.add(value);
}

test "branch hands every item to each sub-pipe" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ map(double), subscribe(toLeft) }),
        pipe(.{ filter(isEven), subscribe(toRight) }),
    })});
    try program(range(u32, 0, 5), work).run(.{ Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 2, 4, 6, 8 });
    try right.expect(&.{ 0, 2, 4 });
}

const Pulls = struct { count: usize = 0 };
fn countPull(pulls: *Pulls, _: u32) void {
    pulls.count += 1;
}

test "a branch stops the source once every sub-pipe is done" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var pulls: Pulls = .{};
    const work = pipe(.{ tap(countPull), branch(.{
        pipe(.{ take(2), subscribe(toLeft) }),
        pipe(.{ take(4), subscribe(toRight) }),
    }) });
    try program(range(u32, 0, 1000), work).run(.{ &pulls, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 1 });
    try right.expect(&.{ 0, 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 4), pulls.count);
}

test "branches finish in order when the stream ends" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ fold(@as(u32, 0), add), subscribe(toLeft) }),
        pipe(.{ map(double), fold(@as(u32, 0), add), subscribe(toRight) }),
    })});
    try program(range(u32, 1, 5), work).run(.{ Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{10});
    try right.expect(&.{20});
}

test "a branch that starts with a queue runs beside its siblings" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(4), map(slowly), subscribe(toLeft) }),
        pipe(.{ queue(4), map(double), subscribe(toRight) }),
    })});
    try program(range(u32, 0, 30), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectEqual(@as(usize, 30), left.len);
    try std.testing.expectEqual(@as(usize, 30), right.len);
    for (left.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    for (right.slice(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i * 2)), value);
}

test "an error in a queued branch fails the run" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), map(failAtFive), subscribe(toLeft) }),
        pipe(.{ queue(2), subscribe(toRight) }),
    })});
    const result = program(range(u32, 0, 20), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Five, result);
    try left.expect(&.{ 0, 1, 2, 3, 4 });
}

test "branches nest" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{subscribe(record)}),
        pipe(.{ map(double), branch(.{ pipe(.{subscribe(toLeft)}), pipe(.{ filter(isEven), take(1), subscribe(toRight) }) }) }),
    })});
    try program(range(u32, 1, 4), work).run(.{ &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try seen.expect(&.{ 1, 2, 3 });
    try left.expect(&.{ 2, 4, 6 });
    try right.expect(&.{2});
}

// --- route ----------------------------------------------------------------

fn isSmall(value: u32) bool {
    return value < 3;
}

test "route sends each item to the first case that takes it" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{route(.{
        when(isSmall, pipe(.{subscribe(toLeft)})),
        when(isEven, pipe(.{subscribe(toRight)})),
        otherwise(pipe(.{subscribe(record)})),
    })});
    try program(range(u32, 0, 8), work).run(.{ &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 1, 2 });
    try right.expect(&.{ 4, 6 });
    try seen.expect(&.{ 3, 5, 7 });
}

test "an item no case takes is dropped" {
    var left: Numbers = .{};
    const work = pipe(.{route(.{when(isSmall, pipe(.{subscribe(toLeft)}))})});
    try program(range(u32, 0, 8), work).run(.{Left{ .seen = &left }});
    try left.expect(&.{ 0, 1, 2 });
}

fn plusHundred(value: u32) u32 {
    return value + 100;
}

test "cases that emit the same type rejoin the pipe" {
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{map(double)})),
            otherwise(pipe(.{map(plusHundred)})),
        }),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{&seen});
    try seen.expect(&.{ 0, 101, 4, 103, 8 });
}

test "a rejoining route stops when the pipe after it is done" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    const work = pipe(.{
        tap(countPull),
        route(.{ when(isEven, pipe(.{map(double)})), otherwise(pipe(.{map(plusHundred)})) }),
        take(2),
        subscribe(record),
    });
    try program(range(u32, 0, 1000), work).run(.{ &seen, &pulls });
    try seen.expect(&.{ 0, 101 });
    try std.testing.expectEqual(@as(usize, 2), pulls.count);
}

test "a case keeps its own state and finishes with the stream" {
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{fold(@as(u32, 0), add)})),
            otherwise(pipe(.{take(1)})),
        }),
        subscribe(record),
    });
    try program(range(u32, 0, 7), work).run(.{&seen});
    try seen.expect(&.{ 1, 12 });
}

test "once the pipe after a route is done, no case forwards to it again" {
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    // Both cases emit one final value when the stream ends; only the first
    // may reach what follows the route.
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{fold(@as(u32, 0), add)})),
            otherwise(pipe(.{fold(@as(u32, 100), add)})),
        }),
        tap(countPull),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped });
    try seen.expect(&.{6});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
}

/// Emits one value as the run starts, before any item arrives.
const Herald = struct {
    value: u32,

    pub const zrx_operator = {};
    pub const name = "herald";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            value: u32,

            pub fn init(self: *@This(), op: *const Herald, _: Env) !void {
                self.value = op.value;
            }

            pub fn start(self: *@This(), down: anytype) !void {
                _ = try down.push(self.value);
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test "a route remembers that the pipe after it is done, even from before the first item" {
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    // The first case emits as the run starts and that satisfies take(1):
    // no item may reach the tap afterwards, through either case.
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{Herald{ .value = 100 }})),
            otherwise(pipe(.{map(double)})),
        }),
        tap(countPull),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped });
    try seen.expect(&.{100});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
}

test "every case starts, but a start emission does not get past a pipe that is done" {
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    // Both cases emit as the run starts. The first satisfies take(1); the
    // second still starts, and what it emits is dropped.
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{Herald{ .value = 100 }})),
            otherwise(pipe(.{Herald{ .value = 200 }})),
        }),
        tap(countPull),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped });
    try seen.expect(&.{100});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
}

const Threshold = struct { value: u32 };
fn above(threshold: Threshold, value: u32) bool {
    return value > threshold.value;
}

test "case predicates use dependencies, and cases can provide their own" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{route(.{
        when(above, pipe(.{ provide(Threshold{ .value = 5 }), filter(above), subscribe(toLeft) })),
        otherwise(pipe(.{subscribe(toRight)})),
    })});
    try program(range(u32, 0, 8), work).run(.{ Threshold{ .value = 2 }, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 6, 7 });
    try right.expect(&.{ 0, 1, 2 });
}

test "terminal cases can be queued" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{route(.{
        when(isEven, pipe(.{ queue(2), subscribe(toLeft) })),
        otherwise(pipe(.{ queue(2), map(double), subscribe(toRight) })),
    })});
    try program(range(u32, 0, 6), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 0, 2, 4 });
    try right.expect(&.{ 2, 6, 10 });
}
