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

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                return down.push(self.value);
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

const Started = struct { count: usize = 0 };

/// Records that it was started; emits nothing.
const StartMark = struct {
    pub const zrx_operator = {};
    pub const name = "startMark";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            started: *Started,

            pub fn init(self: *@This(), _: *const StartMark, env: Env) !void {
                self.started = zrx.di.get(env, *Started);
            }

            pub fn start(self: *@This(), _: anytype) !zrx.Flow {
                self.started.count += 1;
                return .more;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test "once a start emission satisfied the pipe after a route, no later case is started" {
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    var started: Started = .{};
    // The first case emits as the run starts and that satisfies take(1).
    // Nothing the other cases could emit would get anywhere, so their start
    // hooks, which might block, are not run.
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{Herald{ .value = 100 }})),
            when(isSmall, pipe(.{ StartMark{}, Herald{ .value = 200 } })),
            otherwise(pipe(.{StartMark{}})),
        }),
        tap(countPull),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped, &started });
    try seen.expect(&.{100});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
    try std.testing.expectEqual(@as(usize, 0), started.count);
}

test "a case that is done by itself does not keep the other cases from starting" {
    var seen: Numbers = .{};
    var started: Started = .{};
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{ Herald{ .value = 100 }, take(1) })),
            otherwise(pipe(.{ StartMark{}, map(double) })),
        }),
        subscribe(record),
    });
    try program(range(u32, 0, 4), work).run(.{ &seen, &started });
    try seen.expect(&.{ 100, 2, 6 });
    try std.testing.expectEqual(@as(usize, 1), started.count);
}

test "a route that takes no more items still delivers what its cases emit at the end" {
    // Each case is satisfied by its own start emission, so the route is done
    // before the first item and the source is never run. The pipe after the
    // route is not done: it still gets each case's final value.
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, pipe(.{ Herald{ .value = 1 }, take(1), fold(@as(u32, 10), add) })),
            otherwise(pipe(.{ Herald{ .value = 1 }, take(1), fold(@as(u32, 20), add) })),
        }),
        subscribe(record),
    });
    try program(zrx.fromProducer(u32, sourceMustNotRun), work).run(.{&seen});
    try seen.expect(&.{ 11, 21 });
}

fn sourceMustNotRun(_: anytype) error{SourceRan}!void {
    return error.SourceRan;
}

test "once the pipe after a route is done, no case runs a handler for its own final value" {
    // The first case's final value satisfies take(1). The second case still
    // finishes, but its final value would get nowhere: the tap inside that
    // case does not run for it.
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    const at_the_end = pipe(.{
        route(.{
            when(isEven, pipe(.{ fold(@as(u32, 0), add), tap(countPull) })),
            otherwise(pipe(.{ fold(@as(u32, 0), add), tap(countPull) })),
        }),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 4), at_the_end).run(.{ &seen, &tapped });
    try seen.expect(&.{2});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);

    // The same when that pipe was already done as the run started, and for
    // a route inside the case.
    var early: Numbers = .{};
    var untouched: Pulls = .{};
    const inner = pipe(.{route(.{
        when(isSmall, pipe(.{ fold(@as(u32, 0), add), tap(countPull) })),
        otherwise(pipe(.{ fold(@as(u32, 0), add), tap(countPull) })),
    })});
    const from_the_start = pipe(.{
        route(.{
            when(isEven, pipe(.{ fold(@as(u32, 0), add), tap(countPull) })),
            when(isSmall, inner),
            otherwise(pipe(.{Herald{ .value = 100 }})),
        }),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 4), from_the_start).run(.{ &early, &untouched });
    try early.expect(&.{100});
    try std.testing.expectEqual(@as(usize, 0), untouched.count);
}

const Answer = struct { flow: ?zrx.Flow = null };

/// Forwards every item, emits one more at the end of the stream, and
/// records what that one was answered.
const Probe = struct {
    value: u32,

    pub const zrx_operator = {};
    pub const name = "probe";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            value: u32,
            answer: *Answer,

            pub fn init(self: *@This(), op: *const Probe, env: Env) !void {
                self.* = .{ .value = op.value, .answer = zrx.di.get(env, *Answer) };
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                self.answer.flow = try down.push(self.value);
            }
        };
    }
};

test "what a stage emits after the pipe behind it is done reaches no stage" {
    // take(1) is done after the first item. The probe still emits at the end
    // of the stream: the tap between them does not run for that value.
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    var answer: Answer = .{};
    const tapping = pipe(.{ Probe{ .value = 9 }, tap(countPull), take(1), subscribe(record) });
    try program(range(u32, 0, 5), tapping).run(.{ &seen, &tapped, &answer });
    try seen.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 1), tapped.count);
    try std.testing.expectEqual(@as(?zrx.Flow, .done), answer.flow);

    // The answer stays `.done`, even through a filter that would have
    // dropped the value and said `.more`.
    var filtered: Numbers = .{};
    var second: Answer = .{};
    const filtering = pipe(.{ Probe{ .value = 9 }, filter(isEven), take(1), subscribe(record) });
    try program(range(u32, 0, 5), filtering).run(.{ &filtered, &second });
    try filtered.expect(&.{0});
    try std.testing.expectEqual(@as(?zrx.Flow, .done), second.flow);
}

test "a start emission after the pipe behind it is done reaches no stage either" {
    // The herald's value satisfies take(1), so the source is never run. The
    // probe before it still emits at the end of the stream.
    var seen: Numbers = .{};
    var tapped: Pulls = .{};
    var answer: Answer = .{};
    const work = pipe(.{ Probe{ .value = 9 }, tap(countPull), Herald{ .value = 1 }, take(1), subscribe(record) });
    try program(range(u32, 0, 5), work).run(.{ &seen, &tapped, &answer });
    try seen.expect(&.{1});
    try std.testing.expectEqual(@as(usize, 0), tapped.count);
    try std.testing.expectEqual(@as(?zrx.Flow, .done), answer.flow);
}

fn evenOrFail(value: u32) error{PredicateFailed}!bool {
    if (value == 0) return error.PredicateFailed;
    return value % 2 == 0;
}

test "a predicate cannot fail the run over an item a done route no longer takes" {
    var seen: Numbers = .{};
    // A start emission satisfies take(1). The first source item would make
    // the predicate fail, but nothing wants that item any more.
    const work = pipe(.{
        route(.{
            when(evenOrFail, pipe(.{Herald{ .value = 100 }})),
            otherwise(pipe(.{map(double)})),
        }),
        take(1),
        subscribe(record),
    });
    try program(range(u32, 0, 5), work).run(.{&seen});
    try seen.expect(&.{100});
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

const Gate = struct { opened: std.Io.Event = .unset };

/// A final value's handler that blocks, after saying it has started.
fn announceThenBlock(clock: std.Io, gate: *Gate, flags: *Flags, _: u32) !void {
    gate.opened.set(clock);
    try clock.sleep(.fromSeconds(5), .awake);
    flags.woke_by_itself.store(true, .seq_cst);
}
fn failOnceAnnounced(clock: std.Io, gate: *Gate, _: u32) !void {
    try gate.opened.wait(clock);
    return error.ConsumerBroke;
}

test "a failure while a final value's handler is blocked ends the run" {
    // The source is finite and has ended. The fold's final value is being
    // delivered, and its handler is waiting, when the queued sibling fails.
    var flags: Flags = .{};
    var gate: Gate = .{};
    const work = pipe(.{branch(.{
        pipe(.{ fold(@as(u32, 0), add), subscribe(announceThenBlock) }),
        pipe(.{ queue(2), subscribe(failOnceAnnounced) }),
    })});
    const result = program(range(u32, 0, 2), work).run(.{ io, &flags, &gate });
    try std.testing.expectError(error.ConsumerBroke, result);
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

/// The synchronous branch's handler: lets the queued branch finish with the
/// same item first.
fn afterTheQueuedBranch(clock: std.Io, gate: *Gate, value: u32) !void {
    _ = value;
    try gate.opened.wait(clock);
    // The queued branch marks itself done just after its handler returns.
    try clock.sleep(.fromMilliseconds(20), .awake);
}
fn openTheGate(clock: std.Io, gate: *Gate, _: u32) void {
    gate.opened.set(clock);
}
/// Stops when told, and otherwise waits far longer than a test should take.
fn pushThenIdleUnlessDone(clock: std.Io, flags: *Flags, out: anytype) !void {
    if (try out.push(@as(u32, 1)) == .done) return;
    try clock.sleep(.fromSeconds(5), .awake);
    flags.woke_by_itself.store(true, .seq_cst);
}

test "a branch is done when its last sub-pipe is, whichever kind finished last" {
    // The queued branch becomes done while the synchronous one is still
    // working on the same item; then that one is done too.
    var flags: Flags = .{};
    var gate: Gate = .{};
    const work = pipe(.{branch(.{
        pipe(.{ queue(2), take(1), subscribe(openTheGate) }),
        pipe(.{ take(1), subscribe(afterTheQueuedBranch) }),
    })});
    try program(zrx.fromProducer(u32, pushThenIdleUnlessDone), work).run(.{ io, &flags, &gate });
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

/// Pushes one value into what follows as the run starts, then waits far
/// longer than a test should take.
const BlockingHerald = struct {
    pub const zrx_operator = {};
    pub const name = "blockingHerald";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            clock: std.Io,
            flags: *Flags,

            pub fn init(self: *@This(), _: *const BlockingHerald, env: Env) !void {
                self.* = .{ .clock = zrx.di.get(env, std.Io), .flags = zrx.di.get(env, *Flags) };
            }

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                _ = try down.push(@as(In, 1));
                try self.clock.sleep(.fromSeconds(5), .awake);
                self.flags.woke_by_itself.store(true, .seq_cst);
                return .more;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test "a failure while a start hook is blocked ends the run" {
    // The start hook pushes into the queue and then waits. The queued
    // subscriber fails on that item before any source item exists.
    var flags: Flags = .{};
    const work = pipe(.{ BlockingHerald{}, queue(2), subscribe(failAlways) });
    const result = program(range(u32, 0, 3), work).run(.{ io, &flags });
    try std.testing.expectError(error.ConsumerBroke, result);
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

/// A source that turns the closed pipe into an error of its own.
fn complainWhenClosed(out: anytype) !void {
    var value: u32 = 0;
    while (true) : (value += 1) {
        if (try out.push(value) == .done) return error.SourceSawClosed;
    }
}

test "the failure that closed a queue is the result, not the producer's reaction to it" {
    for (0..200) |_| {
        const result = program(zrx.fromProducer(u32, complainWhenClosed), pipe(.{ queue(2), subscribe(failAlways) })).run(.{io});
        try std.testing.expectError(error.ConsumerBroke, result);
    }
}

/// As the run starts: pushes one item, waits until the pipe has said it
/// wants no more, and then either returns or blocks.
const SatisfyingHerald = struct {
    then_block: bool,
    /// Inside a sub-pipe: wait for the whole pipe rather than the sub-pipe.
    whole_pipe: bool = false,

    pub const zrx_operator = {};
    pub const name = "satisfyingHerald";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            clock: std.Io,
            flags: *Flags,
            supervision: zrx.operator.Supervision,
            then_block: bool,
            whole_pipe: bool,

            pub fn init(self: *@This(), op: *const SatisfyingHerald, env: Env) !void {
                self.* = .{
                    .clock = zrx.di.get(env, std.Io),
                    .flags = zrx.di.get(env, *Flags),
                    .supervision = zrx.di.get(env, zrx.operator.Supervision),
                    .then_block = op.then_block,
                    .whole_pipe = op.whole_pipe,
                };
            }

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                _ = try down.push(@as(In, 1));
                if (self.then_block) {
                    try self.clock.sleep(.fromSeconds(5), .awake);
                    self.flags.woke_by_itself.store(true, .seq_cst);
                    return .more;
                }
                // Return only once a worker has reported that the pipe is done:
                // the whole of it, or inside a branch or route this sub-pipe.
                const asked: zrx.operator.Supervision = if (self.whole_pipe) .{ .signal = self.supervision.signal } else self.supervision;
                // Waited for without calling into `std.Io`, so that this hook
                // returns by itself instead of being cancelled where it waits.
                while (!asked.wantsNoMore()) std.Thread.yield() catch {};
                return .more;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

const Ran = struct { source: std.atomic.Value(bool) = .init(false) };
fn recordingSource(ran: *Ran, out: anytype) !void {
    ran.source.store(true, .seq_cst);
    _ = try out.push(@as(u32, 7));
}

test "a pipe that is done during startup ends a start hook that is blocked" {
    var flags: Flags = .{};
    var seen: Numbers = .{};
    var ran: Ran = .{};
    const work = pipe(.{ SatisfyingHerald{ .then_block = true }, queue(2), take(1), subscribe(record) });
    try program(zrx.fromProducer(u32, recordingSource), work).run(.{ io, &flags, &seen, &ran });
    try seen.expect(&.{1});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
    try std.testing.expect(!ran.source.load(.seq_cst));
}

test "a pipe that is done when startup returns never runs its source" {
    var flags: Flags = .{};
    var seen: Numbers = .{};
    var ran: Ran = .{};
    const work = pipe(.{ SatisfyingHerald{ .then_block = false }, queue(2), take(1), subscribe(record) });
    try program(zrx.fromProducer(u32, recordingSource), work).run(.{ io, &flags, &seen, &ran });
    try seen.expect(&.{1});
    try std.testing.expect(!ran.source.load(.seq_cst));
}

fn mustNotRun(_: anytype) error{SourceRan}!void {
    return error.SourceRan;
}

test "a start emission that is all the pipe wanted keeps the source from running, queue or not" {
    // The answer comes back to the start hook itself: no worker ever sees it.
    var queued: Numbers = .{};
    const with_queue = pipe(.{ Herald{ .value = 1 }, take(1), queue(2), subscribe(record) });
    try program(zrx.fromProducer(u32, mustNotRun), with_queue).run(.{ io, &queued });
    try queued.expect(&.{1});

    var direct: Numbers = .{};
    const without = pipe(.{ Herald{ .value = 1 }, take(1), subscribe(record) });
    try program(zrx.fromProducer(u32, mustNotRun), without).run(.{&direct});
    try direct.expect(&.{1});
}

test "inside a branch, startup has satisfied the pipe only when it has satisfied every sub-pipe" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const both = pipe(.{branch(.{
        pipe(.{ Herald{ .value = 100 }, take(1), subscribe(toLeft) }),
        pipe(.{ Herald{ .value = 200 }, take(1), queue(2), subscribe(toRight) }),
    })});
    try program(zrx.fromProducer(u32, mustNotRun), both).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{100});
    try right.expect(&.{200});

    var first: Numbers = .{};
    var second: Numbers = .{};
    const one = pipe(.{branch(.{
        pipe(.{ Herald{ .value = 100 }, take(1), subscribe(toLeft) }),
        pipe(.{subscribe(toRight)}),
    })});
    try program(range(u32, 0, 3), one).run(.{ Left{ .seen = &first }, Right{ .seen = &second } });
    try first.expect(&.{100});
    try second.expect(&.{ 0, 1, 2 });
}

test "a queue that was never started takes nothing at the end of the stream" {
    // The start emission satisfies the pipe, so startup is cut short before
    // the first queue is started. The two stages before it still emit at the
    // end of the stream: with nobody to take them, one would fill the queue
    // and the other would wait for space forever.
    var seen: Numbers = .{};
    const work = pipe(.{
        Trailer{ .value = 8 },
        Trailer{ .value = 9 },
        queue(1),
        Herald{ .value = 1 },
        take(1),
        subscribe(record),
    });
    try program(zrx.fromProducer(u32, mustNotRun), work).run(.{ io, &seen });
    try seen.expect(&.{1});
}

test "the same when a worker's answer cut startup short" {
    var flags: Flags = .{};
    var seen: Numbers = .{};
    const work = pipe(.{
        Trailer{ .value = 8 },
        Trailer{ .value = 9 },
        queue(1),
        SatisfyingHerald{ .then_block = true },
        queue(2),
        take(1),
        subscribe(record),
    });
    try program(zrx.fromProducer(u32, mustNotRun), work).run(.{ io, &flags, &seen });
    try seen.expect(&.{1});
    try std.testing.expect(!flags.woke_by_itself.load(.seq_cst));
}

/// Its start hook fails.
const FailingStart = struct {
    pub const zrx_operator = {};
    pub const name = "failingStart";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const FailingStart, _: Env) !void {}

            pub fn start(_: *@This(), _: anytype) error{StartedAfterDone}!zrx.Flow {
                return error.StartedAfterDone;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test "once a worker's answer has satisfied the pipe during startup, no earlier stage is started" {
    // The herald's start hook returns only after the worker behind the queue
    // has reported that the pipe is done, so the order does not depend on
    // timing: whatever comes before the herald must not be started, be it a
    // stage, the cases of a route, or a stage whose start would fail the run.
    for (0..50) |_| {
        var flags: Flags = .{};
        var seen: Numbers = .{};
        var started: Started = .{};
        const plain = pipe(.{ StartMark{}, SatisfyingHerald{ .then_block = false }, queue(2), take(1), subscribe(record) });
        try program(zrx.fromProducer(u32, mustNotRun), plain).run(.{ io, &flags, &seen, &started });
        try seen.expect(&.{1});
        try std.testing.expectEqual(@as(usize, 0), started.count);

        var routed_seen: Numbers = .{};
        const routed = pipe(.{
            route(.{
                when(isEven, pipe(.{StartMark{}})),
                otherwise(pipe(.{StartMark{}})),
            }),
            SatisfyingHerald{ .then_block = false },
            queue(2),
            take(1),
            subscribe(record),
        });
        try program(zrx.fromProducer(u32, mustNotRun), routed).run(.{ io, &flags, &routed_seen, &started });
        try routed_seen.expect(&.{1});
        try std.testing.expectEqual(@as(usize, 0), started.count);

        var failing_seen: Numbers = .{};
        const failing = pipe(.{ FailingStart{}, SatisfyingHerald{ .then_block = false }, queue(2), take(1), subscribe(record) });
        try program(zrx.fromProducer(u32, mustNotRun), failing).run(.{ io, &flags, &failing_seen });
        try failing_seen.expect(&.{1});
    }
}

test "the same for the next case of a route, and for the rest of a sub-pipe" {
    for (0..50) |_| {
        // Inside a branch it is the sub-pipe's own worker that counts: the
        // sibling wants every item, so the pipe as a whole is not done.
        var left: Numbers = .{};
        var right: Numbers = .{};
        var arm_flags: Flags = .{};
        var arm_started: Started = .{};
        const arms = pipe(.{branch(.{
            pipe(.{ StartMark{}, SatisfyingHerald{ .then_block = false }, queue(2), take(1), subscribe(toLeft) }),
            pipe(.{subscribe(toRight)}),
        })});
        try program(range(u32, 5, 8), arms).run(.{ io, &arm_flags, &arm_started, Left{ .seen = &left }, Right{ .seen = &right } });
        try left.expect(&.{1});
        try right.expect(&.{ 5, 6, 7 });
        try std.testing.expectEqual(@as(usize, 0), arm_started.count);

        // And the same for a case of a route that ends there.
        var even: Numbers = .{};
        var odd: Numbers = .{};
        const ending = pipe(.{route(.{
            when(isEven, pipe(.{ StartMark{}, SatisfyingHerald{ .then_block = false }, queue(2), take(1), subscribe(toLeft) })),
            otherwise(pipe(.{subscribe(toRight)})),
        })});
        try program(range(u32, 5, 8), ending).run(.{ io, &arm_flags, &arm_started, Left{ .seen = &even }, Right{ .seen = &odd } });
        try even.expect(&.{1});
        try odd.expect(&.{ 5, 7 });
        try std.testing.expectEqual(@as(usize, 0), arm_started.count);
    }
    for (0..50) |_| {
        // The first case's value satisfies the pipe behind the queue. That is
        // a worker's answer, not one to anything the case pushed.
        var flags: Flags = .{};
        var seen: Numbers = .{};
        var started: Started = .{};
        const cases = pipe(.{
            route(.{
                when(isEven, pipe(.{SatisfyingHerald{ .then_block = false, .whole_pipe = true }})),
                otherwise(pipe(.{StartMark{}})),
            }),
            queue(2),
            take(1),
            subscribe(record),
        });
        try program(zrx.fromProducer(u32, mustNotRun), cases).run(.{ io, &flags, &seen, &started });
        try seen.expect(&.{1});
        try std.testing.expectEqual(@as(usize, 0), started.count);
    }
}

// --- startup, wherever it is and whatever happens meanwhile ----------------------
//
// One stage emits as the run starts and returns only once a worker has
// reported: that the sub-pipe ending in the queue wants no more, or that it
// failed. Everything that startup would still get to after that stage (the
// stage before it, the next case of every route around it, the stages before
// those routes) must not be started, however deep the stage sits.

/// As the run starts: pushes one item and waits, without calling into
/// `std.Io`, until a worker has reported.
const Until = struct {
    wait: enum { satisfied, failed },
    /// How many routes lie between this stage and the pipe the queue is in.
    levels: usize,

    pub const zrx_operator = {};
    pub const name = "until";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            supervision: zrx.operator.Supervision,
            wait: @FieldType(Until, "wait"),
            levels: usize,

            pub fn init(self: *@This(), op: *const Until, env: Env) !void {
                self.* = .{ .supervision = zrx.di.get(env, zrx.operator.Supervision), .wait = op.wait, .levels = op.levels };
            }

            /// Whether the pipe the queue is in wants no more: the whole
            /// pipe, or the arm of a branch. Read from the scopes
            /// themselves, not through the function startup uses.
            fn queuedPipeIsSatisfied(self: *const @This()) bool {
                var at = self.supervision;
                for (0..self.levels) |_| at = at.scope.?.parent;
                if (at.scope) |scope| return scope.done[at.arm].load(.seq_cst);
                return at.signal.has_satisfied.load(.acquire);
            }

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                _ = try down.push(@as(In, 1));
                switch (self.wait) {
                    .satisfied => while (!self.queuedPipeIsSatisfied()) std.Thread.yield() catch {},
                    .failed => while (!self.supervision.hasFailed()) std.Thread.yield() catch {},
                }
                return .more;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

/// What comes before the queue, with the waiting stage `depth` routes deep
/// and a stage that must not be started at every place startup still passes.
fn beforeTheQueue(comptime depth: usize, comptime wait: @FieldType(Until, "wait")) Nesting(depth, depth, wait).Pipe {
    return Nesting(depth, depth, wait).inside;
}

fn Nesting(comptime remaining: usize, comptime depth: usize, comptime wait: @FieldType(Until, "wait")) type {
    return struct {
        const inside = if (remaining == 0) pipe(.{ StartMark{}, Until{ .wait = wait, .levels = depth } }) else pipe(.{
            StartMark{},
            route(.{
                when(isEven, Nesting(remaining - 1, depth, wait).inside),
                otherwise(pipe(.{StartMark{}})),
            }),
        });
        const Pipe = @TypeOf(inside);
    };
}

test "a sub-pipe that is done stops startup at any depth inside it" {
    inline for (0..4) |depth| {
        for (0..25) |_| {
            // The whole pipe: the source is never run.
            var seen: Numbers = .{};
            var started: Started = .{};
            const whole = pipe(.{ beforeTheQueue(depth, .satisfied), queue(2), take(1), subscribe(record) });
            try program(zrx.fromProducer(u32, mustNotRun), whole).run(.{ io, &seen, &started });
            try seen.expect(&.{1});
            try std.testing.expectEqual(@as(usize, 0), started.count);

            // One arm of a branch whose other arm wants every item: nothing
            // cancels startup here, so nothing but the check stops it.
            var left: Numbers = .{};
            var right: Numbers = .{};
            const arm = pipe(.{branch(.{
                pipe(.{ beforeTheQueue(depth, .satisfied), queue(2), take(1), subscribe(toLeft) }),
                pipe(.{subscribe(toRight)}),
            })});
            try program(range(u32, 5, 8), arm).run(.{ io, &started, Left{ .seen = &left }, Right{ .seen = &right } });
            try left.expect(&.{1});
            try right.expect(&.{ 5, 6, 7 });
            try std.testing.expectEqual(@as(usize, 0), started.count);

            // The same arm one branch further in.
            var inner_left: Numbers = .{};
            var inner_right: Numbers = .{};
            const nested = pipe(.{branch(.{
                pipe(.{branch(.{
                    pipe(.{ beforeTheQueue(depth, .satisfied), queue(2), take(1), subscribe(toLeft) }),
                    pipe(.{drain()}),
                })}),
                pipe(.{subscribe(toRight)}),
            })});
            try program(range(u32, 5, 8), nested).run(.{ io, &started, Left{ .seen = &inner_left }, Right{ .seen = &inner_right } });
            try inner_left.expect(&.{1});
            try inner_right.expect(&.{ 5, 6, 7 });
            try std.testing.expectEqual(@as(usize, 0), started.count);
        }
    }
}

test "a worker's failure stops startup at any depth" {
    inline for (0..4) |depth| {
        for (0..25) |_| {
            var started: Started = .{};
            const whole = pipe(.{ beforeTheQueue(depth, .failed), queue(2), subscribe(failAlways) });
            try std.testing.expectError(error.ConsumerBroke, program(zrx.fromProducer(u32, mustNotRun), whole).run(.{ io, &started }));
            try std.testing.expectEqual(@as(usize, 0), started.count);

            var right: Numbers = .{};
            const arm = pipe(.{branch(.{
                pipe(.{ beforeTheQueue(depth, .failed), queue(2), subscribe(failAlways) }),
                pipe(.{subscribe(toRight)}),
            })});
            try std.testing.expectError(error.ConsumerBroke, program(range(u32, 5, 8), arm).run(.{ io, &started, Right{ .seen = &right } }));
            try std.testing.expectEqual(@as(usize, 0), started.count);
        }
    }
}

// --- a worker's "done" travels against the flow ----------------------------------
//
// When a worker has said that its side wants no more, what comes before it
// may be working, or waiting, for nothing: a worker stuck in a handler
// between two queues, a producer waiting for space, a handler over a final
// value. None of them is waited for, and none of their failures counts.
//
// Reproductions from an adversarial review of 6d1278c. Each of these fails.

/// What the tests below share with their handlers.
const Stuck = struct {
    gate: std.Io.Event = .unset,
    source_woke: std.atomic.Value(bool) = .init(false),
    handler_woke: std.atomic.Value(bool) = .init(false),
    sibling_waited: std.atomic.Value(bool) = .init(false),
    /// The `Supervision` of the pipe `Expose` sits in.
    supervision: ?zrx.operator.Supervision = null,
};

/// Copies the `Supervision` of the pipe it is in to the injected `*Stuck`,
/// so that a handler can wait, without calling into `std.Io`, for what a
/// worker reports.
const Expose = struct {
    pub const zrx_operator = {};
    pub const name = "expose";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Expose, env: Env) !void {
                zrx.di.get(env, *Stuck).supervision = zrx.di.get(env, zrx.operator.Supervision);
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

/// Pushes 1 and 2, says so, then waits far longer than a test should take.
fn pushTwoThenIdle(clock: std.Io, stuck: *Stuck, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    _ = try out.push(@as(u32, 2));
    stuck.gate.set(clock);
    try clock.sleep(.fromSeconds(5), .awake);
    stuck.source_woke.store(true, .seq_cst);
}

/// Between two queues. Item 1 goes on once item 2 is in the queue behind it;
/// item 2 blocks far longer than a test should take.
fn firstWaitsSecondBlocks(clock: std.Io, stuck: *Stuck, value: u32) !void {
    if (value == 1) return stuck.gate.wait(clock);
    try clock.sleep(.fromSeconds(5), .awake);
    stuck.handler_woke.store(true, .seq_cst);
}

test "a pipe that is done does not wait for a handler between two queues" {
    // take(1) is satisfied by item 1, so the whole pipe is done and the idle
    // source is interrupted. The worker between the two queues is meanwhile
    // blocked in its handler over item 2, which nothing wants: the run must
    // not wait for that handler (it would be cancelled had the pipe failed).
    var stuck: Stuck = .{};
    var seen: Numbers = .{};
    const work = pipe(.{
        queue(4),
        tap(firstWaitsSecondBlocks),
        queue(4),
        take(1),
        subscribe(record),
    });
    try program(zrx.fromProducer(u32, pushTwoThenIdle), work).run(.{ io, &stuck, &seen });
    try seen.expect(&.{1});
    try std.testing.expect(!stuck.source_woke.load(.seq_cst));
    try std.testing.expect(!stuck.handler_woke.load(.seq_cst));
}

fn pushOneThenIdle(clock: std.Io, stuck: *Stuck, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    try clock.sleep(.fromSeconds(5), .awake);
    stuck.source_woke.store(true, .seq_cst);
}

/// Blocks over the final value only.
fn blockOnNine(clock: std.Io, stuck: *Stuck, value: u32) !void {
    if (value != 9) return;
    try clock.sleep(.fromSeconds(5), .awake);
    stuck.handler_woke.store(true, .seq_cst);
}

test "a final value before a queue that is done reaches no handler" {
    // The pipe has been done since item 1. The trailer's final value is
    // dropped where it is emitted: the queue ahead of it can tell that it
    // takes no more, so the handler in between, which would block, never runs.
    var stuck: Stuck = .{};
    var seen: Numbers = .{};
    const work = pipe(.{
        Trailer{ .value = 9 },
        tap(blockOnNine),
        queue(4),
        take(1),
        subscribe(record),
    });
    try program(zrx.fromProducer(u32, pushOneThenIdle), work).run(.{ io, &stuck, &seen });
    try seen.expect(&.{1});
    try std.testing.expect(!stuck.source_woke.load(.seq_cst));
    try std.testing.expect(!stuck.handler_woke.load(.seq_cst));
}

/// On the source's side of the first queue. Over the last item: lets the far
/// side finish, and goes on only once that has made this sub-pipe done.
fn lastWaitsUntilDone(clock: std.Io, stuck: *Stuck, value: u32) void {
    if (value != 4) return;
    stuck.gate.set(clock);
    while (!stuck.supervision.?.wantsNoMore()) std.Thread.yield() catch {};
}
/// Between the queues: item 2 blocks far longer than a test should take.
fn secondBlocks(clock: std.Io, stuck: *Stuck, value: u32) !void {
    if (value != 2) return;
    try clock.sleep(.fromSeconds(5), .awake);
    stuck.handler_woke.store(true, .seq_cst);
}
fn waitForTheGate(clock: std.Io, stuck: *Stuck, _: u32) !void {
    try stuck.gate.wait(clock);
}
/// The sibling: records whether its last item only came once the handler in
/// the sub-pipe that is done had woken by itself.
fn siblingSees(stuck: *Stuck, sink: Right, value: u32) void {
    if (value == 4 and stuck.handler_woke.load(.seq_cst)) stuck.sibling_waited.store(true, .seq_cst);
    sink.seen.add(value);
}

test "a sub-pipe that is done does not keep items from its sibling" {
    // The first sub-pipe is done (its far side took one item and said so)
    // before the source hands it item 4. Its first queue is full, because
    // the worker behind it is blocked in a handler over item 2. The source
    // then waits for that handler, and so does the sibling, which wants
    // every item.
    var stuck: Stuck = .{};
    var right: Numbers = .{};
    const done_early = pipe(.{
        Expose{},
        tap(lastWaitsUntilDone),
        queue(1),
        tap(secondBlocks),
        queue(1),
        take(1),
        subscribe(waitForTheGate),
    });
    const work = pipe(.{branch(.{
        done_early,
        pipe(.{subscribe(siblingSees)}),
    })});
    try program(range(u32, 1, 5), work).run(.{ io, &stuck, Right{ .seen = &right } });
    try right.expect(&.{ 1, 2, 3, 4 });
    try std.testing.expect(!stuck.sibling_waited.load(.seq_cst));
}

/// True for 1. Over 2: lets the queued case finish, waits (without calling
/// into `std.Io`) until that has made the route done, and only then fails.
fn failsOnceTheRouteIsDone(clock: std.Io, stuck: *Stuck, value: u32) error{PredicateFailed}!bool {
    if (value == 1) return true;
    stuck.gate.set(clock);
    while (!stuck.supervision.?.wantsNoMore()) std.Thread.yield() catch {};
    return error.PredicateFailed;
}

test "a predicate's failure over an item its route no longer wants is not the run's" {
    // The route's only case is done through its worker while the predicate
    // is running for item 2. The sibling wants every item, so nothing
    // cancels the source: the route has to see for itself that the item it
    // failed over is one nobody takes.
    var stuck: Stuck = .{};
    var right: Numbers = .{};
    const routed = pipe(.{
        Expose{},
        route(.{when(failsOnceTheRouteIsDone, pipe(.{ queue(2), take(1), subscribe(waitForTheGate) }))}),
    });
    const work = pipe(.{branch(.{
        routed,
        pipe(.{subscribe(toRight)}),
    })});
    try program(range(u32, 1, 3), work).run(.{ io, &stuck, Right{ .seen = &right } });
    try right.expect(&.{ 1, 2 });
}

/// Fine for 1. Over 2: lets the far side finish, waits (without calling into
/// `std.Io`) until that has made this sub-pipe done, and only then fails.
fn failsOnceDone(clock: std.Io, stuck: *Stuck, value: u32) error{HandlerFailed}!u32 {
    if (value == 1) return value;
    stuck.gate.set(clock);
    while (!stuck.supervision.?.wantsNoMore()) std.Thread.yield() catch {};
    return error.HandlerFailed;
}

/// Pushes 1, waits until that has made the pipe done, and only then fails.
fn sourceFailsOnceDone(clock: std.Io, stuck: *Stuck, out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    stuck.gate.set(clock);
    while (!stuck.supervision.?.wantsNoMore()) std.Thread.yield() catch {};
    return error.SourceFailed;
}

/// As the run starts: pushes one item, waits until that has made its pipe
/// done, and only then fails.
const FailsOnceDone = struct {
    pub const zrx_operator = {};
    pub const name = "failsOnceDone";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            supervision: zrx.operator.Supervision,

            pub fn init(self: *@This(), _: *const FailsOnceDone, env: Env) !void {
                self.supervision = zrx.di.get(env, zrx.operator.Supervision);
            }

            pub fn start(self: *@This(), down: anytype) !zrx.Flow {
                _ = try down.push(@as(In, 1));
                while (!self.supervision.wantsNoMore()) std.Thread.yield() catch {};
                return error.StartFailed;
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test "a failure over something nobody takes any more is not the run's failure" {
    for (0..50) |_| {
        // A handler, in a sub-pipe whose sibling keeps the run going.
        var stuck: Stuck = .{};
        var right: Numbers = .{};
        const handler = pipe(.{branch(.{
            pipe(.{ Expose{}, map(failsOnceDone), queue(2), take(1), subscribe(waitForTheGate) }),
            pipe(.{subscribe(toRight)}),
        })});
        try program(range(u32, 1, 3), handler).run(.{ io, &stuck, Right{ .seen = &right } });
        try right.expect(&.{ 1, 2 });

        // The same in a case of a route.
        var routed_stuck: Stuck = .{};
        var routed_right: Numbers = .{};
        const in_a_case = pipe(.{branch(.{
            pipe(.{route(.{
                when(isEven, pipe(.{drain()})),
                otherwise(pipe(.{ Expose{}, map(failsOnceDone), queue(2), take(1), subscribe(waitForTheGate) })),
            })}),
            pipe(.{subscribe(toRight)}),
        })});
        // 1 goes to the case and satisfies it; 3 is the item it fails over.
        try program(zrx.fromSlice(&[_]u32{ 1, 2, 3, 2 }), in_a_case).run(.{ io, &routed_stuck, Right{ .seen = &routed_right } });
        try routed_right.expect(&.{ 1, 2, 3, 2 });

        // A start hook, in a sub-pipe and in the whole pipe.
        var left: Numbers = .{};
        var started_right: Numbers = .{};
        const hook = pipe(.{branch(.{
            pipe(.{ FailsOnceDone{}, queue(2), take(1), subscribe(toLeft) }),
            pipe(.{subscribe(toRight)}),
        })});
        try program(range(u32, 5, 7), hook).run(.{ io, Left{ .seen = &left }, Right{ .seen = &started_right } });
        try left.expect(&.{1});
        try started_right.expect(&.{ 5, 6 });

        var seen: Numbers = .{};
        const whole = pipe(.{ FailsOnceDone{}, queue(2), take(1), subscribe(record) });
        try program(zrx.fromProducer(u32, mustNotRun), whole).run(.{ io, &seen });
        try seen.expect(&.{1});

        // The source itself, once the whole pipe is done.
        var source_stuck: Stuck = .{};
        var from_source: Numbers = .{};
        const sourced = pipe(.{ Expose{}, queue(2), take(1), subscribe(record) });
        try program(zrx.fromProducer(u32, sourceFailsOnceDone), sourced).run(.{ io, &source_stuck, &from_source });
        try from_source.expect(&.{1});
    }
}

test "a queue before a route case or a branch that is done lets go of its worker" {
    // As for two queues in a row, with the queue that is done one level in:
    // inside a case of a route, whose sibling arm wants every item.
    var stuck: Stuck = .{};
    var right: Numbers = .{};
    const done_early = pipe(.{
        Expose{},
        tap(lastWaitsUntilDone),
        queue(1),
        tap(secondBlocks),
        queue(1),
        take(1),
        subscribe(waitForTheGate),
    });
    const in_a_case = pipe(.{branch(.{
        pipe(.{route(.{otherwise(done_early)})}),
        pipe(.{subscribe(siblingSees)}),
    })});
    try program(range(u32, 1, 5), in_a_case).run(.{ io, &stuck, Right{ .seen = &right } });
    try right.expect(&.{ 1, 2, 3, 4 });
    try std.testing.expect(!stuck.sibling_waited.load(.seq_cst));

    // And with what is done after the queue being a branch: every arm of it.
    var before: Stuck = .{};
    var first: Numbers = .{};
    var second: Numbers = .{};
    const before_a_branch = pipe(.{
        queue(4),
        tap(firstWaitsSecondBlocks),
        branch(.{
            pipe(.{ queue(4), take(1), subscribe(toLeft) }),
            pipe(.{ queue(4), take(1), subscribe(toRight) }),
        }),
    });
    try program(zrx.fromProducer(u32, pushTwoThenIdle), before_a_branch).run(.{ io, &before, Left{ .seen = &first }, Right{ .seen = &second } });
    try first.expect(&.{1});
    try second.expect(&.{1});
    try std.testing.expect(!before.source_woke.load(.seq_cst));
    try std.testing.expect(!before.handler_woke.load(.seq_cst));
}
