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

// --- supervision ------------------------------------------------------------

const Flags = struct {
    released: std.atomic.Value(bool) = .init(false),
    used_after_release: std.atomic.Value(bool) = .init(false),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};
const Handle = struct { flags: *Flags };

fn open(flags: *Flags) Handle {
    return .{ .flags = flags };
}
fn close(handle: Handle) void {
    handle.flags.released.store(true, .seq_cst);
}
fn useSlowly(clock: std.Io, handle: Handle, _: u32) void {
    clock.sleep(.fromMilliseconds(20), .awake) catch {};
    if (handle.flags.released.load(.seq_cst)) handle.flags.used_after_release.store(true, .seq_cst);
}
fn breakAfterOne(out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    return error.SourceBroke;
}

test "a queue's consumer is joined before the resources it uses are released" {
    var flags: Flags = .{};
    const work = pipe(.{ queue(4), zrx.resource(open, close), subscribe(useSlowly) });
    const result = program(zrx.fromProducer(u32, breakAfterOne), work).run(.{ io, &flags });
    try std.testing.expectError(error.SourceBroke, result);
    try std.testing.expect(flags.released.load(.seq_cst));
    try std.testing.expect(!flags.used_after_release.load(.seq_cst));
}

/// Pushes one item, then waits far longer than a test should take. Only a
/// cancellation ends the wait early; waking up by itself is recorded.
fn pushThenIdle(clock: std.Io, flags: *Flags, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    try clock.sleep(.fromSeconds(5), .awake);
    flags.woke_by_itself.store(true, .seq_cst);
    _ = try out.push(@as(u32, 2));
}
fn failAlways(_: u32) error{ConsumerBroke}!void {
    return error.ConsumerBroke;
}

test "a failure behind a queue interrupts a source that is not pushing" {
    var flags: Flags = .{};
    const result = program(zrx.fromProducer(u32, pushThenIdle), pipe(.{ queue(4), subscribe(failAlways) })).run(.{ io, &flags });
    try std.testing.expectError(error.ConsumerBroke, result);
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

test "a pipe that is done behind a queue interrupts a source that is not pushing" {
    var flags: Flags = .{};
    var seen: Numbers = .{};
    try program(zrx.fromProducer(u32, pushThenIdle), pipe(.{ queue(4), take(1), subscribe(record) })).run(.{ io, &flags, &seen });
    try seen.expect(&.{1});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

test "a failure in a queued branch interrupts a source that is not pushing" {
    var flags: Flags = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), subscribe(failAlways) }),
        pipe(.{ queue(2), subscribe(toRight) }),
    })});
    const result = program(zrx.fromProducer(u32, pushThenIdle), work).run(.{ io, &flags, Right{ .seen = &right } });
    try std.testing.expectError(error.ConsumerBroke, result);
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

test "one queued branch being done does not stop its siblings" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), take(1), subscribe(toLeft) }),
        pipe(.{ queue(2), map(slowly), subscribe(toRight) }),
    })});
    try program(range(u32, 0, 20), work).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 20), right.len);
}

fn anyFailure(value: u32) anyerror!void {
    if (value == 3) return error.Three;
}

test "a handler that can fail with anyerror works behind a queue" {
    try std.testing.expectError(error.Three, program(range(u32, 0, 10), pipe(.{ queue(2), subscribe(anyFailure) })).run(.{io}));
    try program(range(u32, 0, 3), pipe(.{ queue(2), subscribe(anyFailure) })).run(.{io});
}

/// Blocks far longer than a test should take; only a cancellation ends it early.
fn blockLong(clock: std.Io, flags: *Flags, _: u32) !void {
    try clock.sleep(.fromSeconds(5), .awake);
    flags.woke_by_itself.store(true, .seq_cst);
}

test "a failure while the run is draining another worker ends the run" {
    // The source is finite and ends at once. The run then joins the first
    // branch, whose worker is stuck; the second branch failing must end that.
    var flags: Flags = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), subscribe(blockLong) }),
        pipe(.{ queue(2), subscribe(failAlways) }),
    })});
    const result = program(range(u32, 0, 2), work).run(.{ io, &flags });
    try std.testing.expectError(error.ConsumerBroke, result);
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

test "nothing finishes normally once a worker has failed" {
    // The fold's final value would be published when the stream ends; the
    // run has failed by then, so it must not be.
    var flags: Flags = .{};
    var published: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ fold(@as(u32, 0), add), subscribe(record) }),
        pipe(.{ queue(2), subscribe(failAlways) }),
    })});
    const result = program(zrx.fromProducer(u32, pushThenIdle), work).run(.{ io, &flags, &published });
    try std.testing.expectError(error.ConsumerBroke, result);
    try published.expect(&.{});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

/// A source whose own read fails when it is interrupted, as a blocked
/// reader's does.
fn pushThenFailWhenInterrupted(clock: std.Io, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    clock.sleep(.fromSeconds(5), .awake) catch return error.ReadFailed;
    _ = try out.push(@as(u32, 2));
}

test "the failure that ended the run is its result, not what the interrupted source returned" {
    const result = program(zrx.fromProducer(u32, pushThenFailWhenInterrupted), pipe(.{ queue(2), subscribe(failAlways) })).run(.{io});
    try std.testing.expectError(error.ConsumerBroke, result);
}

test "std.Io only has to be provided where the queue needs it" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 3), pipe(.{ zrx.provide(io), queue(1), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 0, 1, 2 });
    const failing = program(zrx.fromProducer(u32, breakAfterOne), pipe(.{ zrx.provide(io), queue(1), drain() }));
    try std.testing.expectError(error.SourceBroke, failing.run(.{}));
}

test "when every queued branch is done, a source that is not pushing is interrupted" {
    var flags: Flags = .{};
    var left: Numbers = .{};
    var right: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), take(1), subscribe(toLeft) }),
        pipe(.{ queue(2), take(1), subscribe(toRight) }),
    })});
    try program(zrx.fromProducer(u32, pushThenIdle), work).run(.{ io, &flags, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{1});
    try right.expect(&.{1});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

test "the same holds for routes, and for branches inside branches" {
    var flags: Flags = .{};
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{branch(.{
        pipe(.{route(.{
            when(isEven, pipe(.{ queue(2), take(1), subscribe(toLeft) })),
            otherwise(pipe(.{ take(1), subscribe(toRight) })),
        })}),
        pipe(.{branch(.{
            pipe(.{ queue(2), take(1), subscribe(record) }),
        })}),
    })});
    try program(zrx.fromProducer(u32, evenOddThenIdle), work).run(.{ io, &flags, &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{2});
    try right.expect(&.{1});
    try seen.expect(&.{1});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

fn evenOddThenIdle(clock: std.Io, flags: *Flags, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    _ = try out.push(@as(u32, 2));
    try clock.sleep(.fromSeconds(5), .awake);
    flags.woke_by_itself.store(true, .seq_cst);
    _ = try out.push(@as(u32, 3));
}
