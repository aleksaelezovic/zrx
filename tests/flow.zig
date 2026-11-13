//! queue, branch and route.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const fromProducer = zrx.fromProducer;
const resource = zrx.resource;
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

/// Forwards every item and emits one more at the end of the stream.
const Trailer = struct {
    value: u32,

    pub const zrx_operator = {};
    pub const name = "trailer";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            value: u32,

            pub fn init(self: *@This(), op: *const Trailer, _: Env) !void {
                self.value = op.value;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                _ = try down.push(self.value);
            }
        };
    }
};

const Asked = struct { count: usize = 0 };
fn countedEven(asked: *Asked, value: u32) bool {
    asked.count += 1;
    return value % 2 == 0;
}

test "a route that is done asks no predicate" {
    var seen: Numbers = .{};
    var asked: Asked = .{};
    // take(1) is done after the first item. The stage before the route still
    // emits at the end of the stream: the route answers for itself, without
    // running a predicate that could fail or block over that item.
    const work = pipe(.{
        Trailer{ .value = 9 },
        route(.{
            when(countedEven, pipe(.{map(double)})),
            otherwise(pipe(.{map(double)})),
        }),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &asked });
    try seen.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 1), asked.count);
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

// --- segments ---------------------------------------------------------------
//
// A queue splits a pipe into segments, each a task of its own. Nothing here
// measures time: a party that should be interrupted waits far longer than a
// test should take and records whether it woke by itself.

/// A clock shared by everything in one test, so that events seen by different
/// tasks can be put in order.
const Ticks = struct {
    next: std.atomic.Value(usize) = .init(0),
};

/// What one `mark` saw, and when. Each mark has a trace of its own: marks in
/// different segments run at the same time.
fn Trace(comptime id: u8) type {
    return struct {
        events: support.Recorder(u8) = .{},
        at: support.Recorder(usize) = .{},

        const tag = id;

        fn add(self: *@This(), ticks: *Ticks, event: u8) void {
            self.events.add(event);
            self.at.add(ticks.next.fetchAdd(1, .seq_cst));
        }

        fn count(self: *const @This(), event: u8) usize {
            return std.mem.count(u8, self.events.slice(), &.{event});
        }

        /// The moment of the only `event`.
        fn when(self: *const @This(), event: u8) !usize {
            try std.testing.expectEqual(@as(usize, 1), self.count(event));
            return self.at.slice()[std.mem.indexOfScalar(u8, self.events.slice(), event).?];
        }
    };
}

/// Passes every item on and records each hook in `*Trace(id)`:
/// `i`nit, `p`ush, `f`inish, `F`lush, `d`einit.
fn mark(comptime id: u8) Mark(id) {
    return .{};
}

fn Mark(comptime id: u8) type {
    return struct {
        pub const zrx_operator = {};
        pub const name = "mark";

        pub fn Out(comptime _: type, comptime In: type) type {
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                trace: *Trace(id),
                ticks: *Ticks,

                pub fn init(self: *@This(), _: *const Mark(id), env: Env) !void {
                    self.* = .{ .trace = zrx.di.get(env, *Trace(id)), .ticks = zrx.di.get(env, *Ticks) };
                    self.trace.add(self.ticks, 'i');
                }

                pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                    self.trace.add(self.ticks, 'p');
                    return down.push(item);
                }

                pub fn finish(self: *@This(), _: anytype) !void {
                    self.trace.add(self.ticks, 'f');
                }

                pub fn flush(self: *@This()) !void {
                    self.trace.add(self.ticks, 'F');
                }

                pub fn deinit(self: *@This()) void {
                    self.trace.add(self.ticks, 'd');
                }
            };
        }
    };
}

test "the end of the stream travels with the data: each segment finishes once, then everything flushes" {
    var seen: Numbers = .{};
    var ticks: Ticks = .{};
    var first: Trace(0) = .{};
    var second: Trace(1) = .{};
    var third: Trace(2) = .{};
    // A slow middle segment behind a queue of one: the source has returned
    // long before the last item is handled.
    const work = pipe(.{
        mark(0),
        queue(1),
        map(slowly),
        mark(1),
        queue(1),
        fold(@as(u32, 0), add),
        mark(2),
        subscribe(record),
    });
    try program(range(u32, 1, 11), work).run(.{ io, &seen, &ticks, &first, &second, &third });
    try seen.expect(&.{55});
    try first.events.expect("ippppppppppfFd");
    try second.events.expect("ippppppppppfFd");
    try third.events.expect("ipfFd");
    // Segments finish in order; nothing is flushed before the last one has
    // finished, and then the last stage flushes first.
    try std.testing.expect(try first.when('f') < try second.when('f'));
    try std.testing.expect(try second.when('f') < try third.when('f'));
    try std.testing.expect(try third.when('f') < try third.when('F'));
    try std.testing.expect(try third.when('F') < try second.when('F'));
    try std.testing.expect(try second.when('F') < try first.when('F'));
    try std.testing.expect(try first.when('F') < try third.when('d'));
    try std.testing.expect(try third.when('d') < try first.when('d'));
}

test "queued sub-pipes of a branch each finish once when the stream ends" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var trunk: Trace(0) = .{};
    var summed: Trace(1) = .{};
    var echoed: Trace(2) = .{};
    const sum = pipe(.{
        queue(2),
        mark(1),
        fold(@as(u32, 0), add),
        subscribe(toLeft),
    });
    const echo = pipe(.{
        queue(2),
        map(slowly),
        mark(2),
        subscribe(toRight),
    });
    const work = pipe(.{
        mark(0),
        branch(.{ sum, echo }),
    });
    try program(range(u32, 1, 6), work).run(.{ io, &ticks, &trunk, &summed, &echoed, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{15});
    try right.expect(&.{ 1, 2, 3, 4, 5 });
    try trunk.events.expect("ipppppfFd");
    try summed.events.expect("ipppppfFd");
    try echoed.events.expect("ipppppfFd");
    try std.testing.expect(try trunk.when('F') > try summed.when('f'));
    try std.testing.expect(try trunk.when('F') > try echoed.when('f'));
}

fn failAnyhow(value: u32) anyerror!u32 {
    if (value == 5) return error.Five;
    return value;
}

test "a queue works in a pipe whose handlers return anyerror" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 10), pipe(.{ queue(2), map(failAnyhow), subscribe(record) })).run(.{ io, &seen });
    try std.testing.expectError(error.Five, result);
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

test "Io may be provided where the queue needs it" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 5), pipe(.{ provide(io), queue(2), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
}

const Stalled = struct {
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

/// A source that pushes `value` and then waits for input that never comes.
fn PushThenStall(comptime value: u32) type {
    return struct {
        fn run(clock: std.Io, stalled: *Stalled, out: anytype) !void {
            _ = try out.push(value);
            try clock.sleep(.fromSeconds(5), .awake);
            stalled.woke_by_itself.store(true, .seq_cst);
        }
    };
}

test "a failure after a queue ends the run while the source is waiting" {
    var seen: Numbers = .{};
    var stalled: Stalled = .{};
    const source = fromProducer(u32, PushThenStall(5).run);
    const result = program(source, pipe(.{ queue(2), map(failAtFive), subscribe(record) })).run(.{ io, &seen, &stalled });
    try std.testing.expectError(error.Five, result);
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

test "a failure behind two queues, or in a queued sub-pipe, ends the run while the source is waiting" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var stalled: Stalled = .{};
    const source = fromProducer(u32, PushThenStall(5).run);
    const deps = .{ io, &stalled, Left{ .seen = &left }, Right{ .seen = &right } };

    const twice = pipe(.{ queue(2), map(double), queue(2), map(failAtTen), subscribe(toLeft) });
    try std.testing.expectError(error.Ten, program(source, twice).run(deps));

    const failing = pipe(.{
        queue(2),
        map(failAtFive),
        subscribe(toLeft),
    });
    const split = pipe(.{branch(.{ failing, pipe(.{subscribe(toRight)}) })});
    try std.testing.expectError(error.Five, program(source, split).run(deps));

    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

fn failAtTen(value: u32) error{Ten}!u32 {
    if (value == 10) return error.Ten;
    return value;
}

/// What the teardown test watches.
const Hold = struct {
    holding: std.atomic.Value(bool) = .init(false),
    outer_released: std.atomic.Value(bool) = .init(false),
    inner_released: std.atomic.Value(bool) = .init(false),
    released_while_held: std.atomic.Value(bool) = .init(false),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};
const Outer = struct { hold: *Hold };
const Inner = struct { hold: *Hold };

fn acquireOuter(hold: *Hold) Outer {
    return .{ .hold = hold };
}
fn releaseOuter(outer: Outer) void {
    outer.hold.outer_released.store(true, .seq_cst);
}
fn acquireInner(hold: *Hold) Inner {
    return .{ .hold = hold };
}
fn releaseInner(inner: Inner) void {
    inner.hold.inner_released.store(true, .seq_cst);
}

/// Holds both resources until it is interrupted, then looks whether either
/// was released under it.
fn holdBoth(clock: std.Io, outer: Outer, inner: Inner, _: u32) !void {
    const hold = outer.hold;
    hold.holding.store(true, .seq_cst);
    clock.sleep(.fromSeconds(5), .awake) catch |err| {
        if (hold.outer_released.load(.seq_cst) or inner.hold.inner_released.load(.seq_cst))
            hold.released_while_held.store(true, .seq_cst);
        return err;
    };
    hold.woke_by_itself.store(true, .seq_cst);
}

/// Fails once the handler behind the queue is at work.
fn pushThenFail(hold: *Hold, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    while (!hold.holding.load(.seq_cst)) std.Thread.yield() catch {};
    return error.SourceFailed;
}

test "nothing is released while a handler behind a queue is still using it" {
    var hold: Hold = .{};
    const work = pipe(.{
        resource(acquireOuter, releaseOuter),
        queue(2),
        resource(acquireInner, releaseInner),
        subscribe(holdBoth),
    });
    const result = program(fromProducer(u32, pushThenFail), work).run(.{ io, &hold });
    try std.testing.expectError(error.SourceFailed, result);
    try std.testing.expect(!hold.woke_by_itself.load(.seq_cst));
    try std.testing.expect(!hold.released_while_held.load(.seq_cst));
    try std.testing.expect(hold.outer_released.load(.seq_cst) and hold.inner_released.load(.seq_cst));
}

/// What the failure-while-draining test watches.
const Ending = struct {
    draining: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
};

/// Sets `Ending.ended` when the stream ends where it stands.
const RaiseAtEnd = struct {
    pub const zrx_operator = {};
    pub const name = "raiseAtEnd";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            ending: *Ending,

            pub fn init(self: *@This(), _: *const RaiseAtEnd, env: Env) !void {
                self.ending = zrx.di.get(env, *Ending);
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), _: anytype) !void {
                self.ending.ended.store(true, .seq_cst);
            }
        };
    }
};

/// Holds the first item until the run interrupts this task, then carries on
/// as if nothing had happened. It waits without sleeping, so that only the
/// run's own check can keep the stream from ending normally here.
fn carryOnWhenInterrupted(clock: std.Io, ending: *Ending, value: u32) u32 {
    ending.draining.store(true, .seq_cst);
    while (!ending.interrupted.load(.seq_cst)) {
        clock.checkCancel() catch ending.interrupted.store(true, .seq_cst);
        std.Thread.yield() catch {};
    }
    return value;
}

/// Fails once its sibling is draining and the stream has ended for both.
fn failOnceDraining(ending: *Ending, _: u32) error{Late}!u32 {
    while (!ending.draining.load(.seq_cst) or !ending.ended.load(.seq_cst)) std.Thread.yield() catch {};
    return error.Late;
}

test "once a segment has failed, no other segment ends its stream normally" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var ticks: Ticks = .{};
    var trunk: Trace(0) = .{};
    var summed: Trace(1) = .{};
    var ending: Ending = .{};
    // The source has ended and this sub-pipe has every item: left alone, it
    // would fold them and emit the sum.
    const draining = pipe(.{
        queue(8),
        map(carryOnWhenInterrupted),
        fold(@as(u32, 0), add),
        mark(1),
        subscribe(toLeft),
    });
    const failing = pipe(.{
        RaiseAtEnd{},
        queue(8),
        map(failOnceDraining),
        subscribe(toRight),
    });
    const work = pipe(.{
        mark(0),
        branch(.{ draining, failing }),
    });
    const result = program(range(u32, 1, 4), work).run(.{ io, &ticks, &trunk, &summed, &ending, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Late, result);
    try left.expect(&.{});
    // The first segment had ended before the failure; nothing flushes.
    try trunk.events.expect("ipppfd");
    try summed.events.expect("id");
}

/// A source that pushes one item, waits until the run interrupts it, and
/// then returns as if it had simply run out. It waits without sleeping, so
/// that only the run's own check can keep the stream from ending normally.
fn pushThenEndWhenInterrupted(clock: std.Io, out: anytype) !void {
    _ = try out.push(@as(u32, 5));
    while (true) {
        clock.checkCancel() catch return;
        std.Thread.yield() catch {};
    }
}

test "a source that returns after a failure elsewhere does not end the stream" {
    var seen: Numbers = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    const work = pipe(.{
        mark(0),
        queue(2),
        map(failAtFive),
        subscribe(record),
    });
    const result = program(fromProducer(u32, pushThenEndWhenInterrupted), work).run(.{ io, &seen, &ticks, &before });
    try std.testing.expectError(error.Five, result);
    try before.events.expect("ipd");
}

const Caught = struct {
    handled: std.atomic.Value(bool) = .init(false),
};
fn noteHandled(caught: *Caught, _: u32) void {
    caught.handled.store(true, .seq_cst);
}

test "cancelling the caller of a queued program cancels every segment and skips the end of the stream" {
    var stalled: Stalled = .{};
    var caught: Caught = .{};
    var ticks: Ticks = .{};
    var before: Trace(0) = .{};
    var after: Trace(1) = .{};
    const work = pipe(.{
        mark(0),
        queue(2),
        mark(1),
        subscribe(noteHandled),
    });
    const waiting = program(fromProducer(u32, PushThenStall(1).run), work);
    const Waiting = @TypeOf(waiting);
    const Deps = struct { std.Io, *Stalled, *Caught, *Ticks, *Trace(0), *Trace(1) };
    const Caller = struct {
        fn run(queued: *const Waiting, deps: Deps) ?anyerror {
            queued.run(deps) catch |err| return err;
            return null;
        }
    };
    var caller = try io.concurrent(Caller.run, .{ &waiting, Deps{ io, &stalled, &caught, &ticks, &before, &after } });
    // An item got through, so both segments are running and the caller waits.
    while (!caught.handled.load(.seq_cst)) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
    try before.events.expect("ipd");
    try after.events.expect("ipd");
}

// --- working for nothing ------------------------------------------------------

test "a waiting source is cancelled once the pipe behind its queue is done" {
    var seen: Numbers = .{};
    var stalled: Stalled = .{};
    const source = fromProducer(u32, PushThenStall(1).run);
    try program(source, pipe(.{ queue(2), take(1), subscribe(record) })).run(.{ io, &seen, &stalled });
    try seen.expect(&.{1});
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

const Busy = struct {
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

/// Passes the first item on and then waits over the second, far longer than
/// a test should take.
fn stallOnSecond(clock: std.Io, busy: *Busy, value: u32) !u32 {
    if (value == 2) {
        try clock.sleep(.fromSeconds(5), .awake);
        busy.woke_by_itself.store(true, .seq_cst);
    }
    return value;
}

fn pushTwoThenStall(clock: std.Io, stalled: *Stalled, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    _ = try out.push(@as(u32, 2));
    try clock.sleep(.fromSeconds(5), .awake);
    stalled.woke_by_itself.store(true, .seq_cst);
}

test "a segment at work between two queues is cancelled once the last one is done" {
    var seen: Numbers = .{};
    var stalled: Stalled = .{};
    var busy: Busy = .{};
    const work = pipe(.{
        queue(2),
        map(stallOnSecond),
        queue(2),
        take(1),
        subscribe(record),
    });
    try program(fromProducer(u32, pushTwoThenStall), work).run(.{ io, &seen, &stalled, &busy });
    try seen.expect(&.{1});
    try std.testing.expect(!busy.woke_by_itself.load(.seq_cst));
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

test "queued sub-pipes that are all done end a waiting source, in a branch and in a route" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var stalled: Stalled = .{};
    const first = pipe(.{
        queue(2),
        take(1),
        subscribe(toLeft),
    });
    const second = pipe(.{
        queue(2),
        take(1),
        subscribe(toRight),
    });
    const deps = .{ io, &stalled, Left{ .seen = &left }, Right{ .seen = &right } };
    try program(fromProducer(u32, pushTwoThenStall), pipe(.{branch(.{ first, second })})).run(deps);
    try left.expect(&.{1});
    try right.expect(&.{1});

    const cases = route(.{ when(isEven, first), otherwise(second) });
    try program(fromProducer(u32, pushTwoThenStall), pipe(.{cases})).run(deps);
    try left.expect(&.{ 1, 2 });
    try right.expect(&.{ 1, 1 });
    try std.testing.expect(!stalled.woke_by_itself.load(.seq_cst));
}

const Direct = struct {
    queued_done: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
};
fn noteQueuedDone(direct: *Direct, _: u32) void {
    direct.queued_done.store(true, .seq_cst);
}

/// Pushes one item, waits until the queued sub-pipe has had it, gives the
/// run every chance to interrupt this task, and pushes the rest.
fn pushAcrossInterruption(clock: std.Io, direct: *Direct, out: anytype) !void {
    _ = try out.push(@as(u32, 0));
    while (!direct.queued_done.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..2000) |_| {
        clock.checkCancel() catch direct.interrupted.store(true, .seq_cst);
        std.Thread.yield() catch {};
    }
    for (1..5) |value| _ = try out.push(@as(u32, @intCast(value)));
}

test "a segment with a direct sub-pipe keeps running after its queued one is done" {
    var seen: Numbers = .{};
    var direct: Direct = .{};
    const queued = pipe(.{
        queue(2),
        take(1),
        subscribe(noteQueuedDone),
    });
    const work = pipe(.{branch(.{ queued, pipe(.{subscribe(record)}) })});
    try program(fromProducer(u32, pushAcrossInterruption), work).run(.{ io, &seen, &direct });
    try seen.expect(&.{ 0, 1, 2, 3, 4 });
    try std.testing.expect(!direct.interrupted.load(.seq_cst));
}
