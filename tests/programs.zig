//! Sources, programs and systems.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const system = zrx.system;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const range = zrx.range;
const fromIterator = zrx.fromIterator;
const fromProducer = zrx.fromProducer;
const merge = zrx.merge;
const mergeTagged = zrx.mergeTagged;
const map = zrx.map;
const fold = zrx.fold;
const take = zrx.take;
const queue = zrx.queue;
const forEach = zrx.forEach;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

fn add(sum: u32, value: u32) u32 {
    return sum + value;
}

test "operator tuples accept reusable pipes and construct fresh state on each run" {
    var seen: Numbers = .{};
    const total = pipe(.{fold(@as(u32, 10), add)});
    const operators = .{ take(2), total, forEach(record) };
    const app = program(range(u32, 1, 6), operators);
    try std.testing.expect(@TypeOf(app) == @TypeOf(program(range(u32, 1, 6), pipe(operators))));
    try support.run(app, .{&seen});
    try support.run(app, .{&seen});
    try seen.expect(&.{ 13, 13 });
}

test "fromValue emits one item" {
    var seen: Numbers = .{};
    try support.run(program(fromValue(@as(u32, 42)), pipe(.{forEach(record)})), .{&seen});
    try seen.expect(&.{42});
}

test "fromSlice accepts slices and array pointers" {
    var seen: Numbers = .{};
    const array = [_]u32{ 1, 2, 3 };
    const slice: []const u32 = array[1..];
    try support.run(program(fromSlice(&array), pipe(.{forEach(record)})), .{&seen});
    try support.run(program(fromSlice(slice), pipe(.{forEach(record)})), .{&seen});
    try seen.expect(&.{ 1, 2, 3, 2, 3 });
}

const Countdown = struct {
    left: u32,

    pub fn next(self: *Countdown) ?u32 {
        if (self.left == 0) return null;
        self.left -= 1;
        return self.left;
    }
};

test "fromIterator pulls until null and leaves the rest when stopped early" {
    var seen: Numbers = .{};
    var all: Countdown = .{ .left = 3 };
    try support.run(program(fromIterator(&all), pipe(.{forEach(record)})), .{&seen});
    var some: Countdown = .{ .left = 10 };
    try support.run(program(fromIterator(&some), pipe(.{ take(2), forEach(record) })), .{&seen});
    try seen.expect(&.{ 2, 1, 0, 9, 8 });
    try std.testing.expectEqual(@as(u32, 8), some.left);
}

const Flaky = struct {
    calls: u32 = 0,

    pub fn next(self: *Flaky) error{Broken}!?u32 {
        self.calls += 1;
        if (self.calls == 3) return error.Broken;
        return self.calls;
    }
};

test "a failing iterator fails the run" {
    var seen: Numbers = .{};
    var flaky: Flaky = .{};
    try std.testing.expectError(error.Broken, support.run(program(fromIterator(&flaky), pipe(.{forEach(record)})), .{&seen}));
    try seen.expect(&.{ 1, 2 });
}

const Start = struct { at: u32 };
fn countUp(start: Start, out: anytype) !void {
    var value = start.at;
    while (try out.push(value) == .more) value += 1;
}

test "fromProducer injects dependencies and stops when told" {
    var seen: Numbers = .{};
    try support.run(program(fromProducer(u32, countUp), pipe(.{ take(3), forEach(record) })), .{ &seen, Start{ .at = 10 } });
    try seen.expect(&.{ 10, 11, 12 });
}

test "a program is a value: every run starts from fresh state" {
    var seen: Numbers = .{};
    const total = program(range(u32, 1, 4), pipe(.{ fold(@as(u32, 0), add), forEach(record) }));
    try support.run(total, .{&seen});
    try support.run(total, .{&seen});
    try seen.expect(&.{ 6, 6 });
}

// --- merge ----------------------------------------------------------------

test "merge delivers every item of every source, each in its own order" {
    var seen: Numbers = .{};
    const low = [_]u32{ 1, 2, 3, 4 };
    const high = [_]u32{ 100, 200, 300 };
    try support.run(program(merge(.{ fromSlice(&low), fromSlice(&high) }), pipe(.{forEach(record)})), .{ io, &seen });
    try std.testing.expectEqual(@as(usize, 7), seen.len);
    var last_low: u32 = 0;
    var last_high: u32 = 0;
    for (seen.slice()) |value| {
        if (value < 100) {
            try std.testing.expect(value > last_low);
            last_low = value;
        } else {
            try std.testing.expect(value > last_high);
            last_high = value;
        }
    }
    try std.testing.expectEqual(@as(u32, 4), last_low);
    try std.testing.expectEqual(@as(u32, 300), last_high);
}

test "merge stops every source when the pipe is done" {
    var seen: Numbers = .{};
    const endless = range(u32, 0, std.math.maxInt(u32));
    try support.run(program(merge(.{ endless, endless }), pipe(.{ take(5), forEach(record) })), .{ io, &seen });
    try std.testing.expectEqual(@as(usize, 5), seen.len);
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failure under merge fails the run" {
    var seen: Numbers = .{};
    const result = support.run(program(merge(.{ range(u32, 0, 100), range(u32, 0, 100) }), pipe(.{ map(failAtTwo), forEach(record) })), .{ io, &seen });
    try std.testing.expectError(error.Two, result);
}

// --- mergeTagged ----------------------------------------------------------

const Side = enum { left, right };
const Sided = zrx.Tagged(Side, u32);
const SidedLog = support.Recorder(Sided);

test "mergeTagged marks every item with the source it came from" {
    var seen: SidedLog = .{};
    const low = [_]u32{ 1, 2, 3, 4 };
    const high = [_]u32{ 100, 200, 300 };
    // Named out of order: the tags, not the order they are written in, decide.
    const sources = mergeTagged(Side, .{ .right = fromSlice(&high), .left = fromSlice(&low) });
    try support.run(program(sources, .{forEach(support.record(Sided))}), .{ io, &seen });
    try std.testing.expectEqual(@as(usize, 7), seen.len);
    var next: std.EnumArray(Side, usize) = .initFill(0);
    for (seen.slice()) |entry| {
        const expected = switch (entry.source) {
            .left => &low,
            .right => &high,
        };
        try std.testing.expectEqual(expected[next.get(entry.source)], entry.item);
        next.getPtr(entry.source).* += 1;
    }
    try std.testing.expectEqual(low.len, next.get(.left));
    try std.testing.expectEqual(high.len, next.get(.right));
}

const Input = union(enum) { count: u32, word: []const u8 };
const Totals = struct { count: u32 = 0, letters: usize = 0 };

fn tally(totals: Totals, input: Input) Totals {
    return switch (input) {
        .count => |count| .{ .count = totals.count + count, .letters = totals.letters },
        .word => |word| .{ .count = totals.count, .letters = totals.letters + word.len },
    };
}

fn keepTotals(out: *Totals, totals: Totals) void {
    out.* = totals;
}

test "mergeTagged feeds each variant of a tagged union from a source of its type" {
    var totals: Totals = .{};
    const words = [_][]const u8{ "ab", "cde" };
    const sources = mergeTagged(Input, .{ .count = range(u32, 1, 5), .word = fromSlice(&words) });
    try support.run(program(sources, .{ fold(Totals{}, tally), forEach(keepTotals) }), .{ io, &totals });
    try std.testing.expectEqual(Totals{ .count = 10, .letters = 5 }, totals);
}

test "mergeTagged stops every source when the pipe is done" {
    var seen: SidedLog = .{};
    const endless = range(u32, 0, std.math.maxInt(u32));
    try support.run(program(mergeTagged(Side, .{ .left = endless, .right = endless }), .{ take(5), forEach(support.record(Sided)) }), .{ io, &seen });
    try std.testing.expectEqual(@as(usize, 5), seen.len);
}

const Only = enum { one };

test "a mergeTagged of one source runs it in place and needs no Io" {
    var seen: support.Recorder(zrx.Tagged(Only, u32)) = .{};
    try support.run(program(mergeTagged(Only, .{ .one = range(u32, 0, 2) }), .{forEach(support.record(zrx.Tagged(Only, u32)))}), .{&seen});
    try seen.expect(&.{ .{ .source = .one, .item = 0 }, .{ .source = .one, .item = 1 } });
}

// --- system ---------------------------------------------------------------

const Left = struct { seen: *Numbers };
const Right = struct { seen: *Numbers };
fn toLeft(sink: Left, value: u32) void {
    sink.seen.add(value);
}
fn toRight(sink: Right, value: u32) void {
    sink.seen.add(value);
}

test "a system runs every program with the same dependencies" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const totals = program(range(u32, 1, 5), pipe(.{ fold(@as(u32, 0), add), forEach(toLeft) }));
    const echo = program(range(u32, 7, 10), pipe(.{ queue(2), forEach(toRight) }));
    try support.run(system(.{ totals, echo }), .{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{10});
    try right.expect(&.{ 7, 8, 9 });
}

test "a merge of one source runs it in place and needs no Io" {
    var seen: Numbers = .{};
    try support.run(program(merge(.{range(u32, 0, 3)}), pipe(.{forEach(record)})), .{&seen});
    try seen.expect(&.{ 0, 1, 2 });
}

test "systems nest, and a system of one needs no Io" {
    // Programs of a system run at the same time: each writes to its own log.
    var left: Numbers = .{};
    var right: Numbers = .{};
    var seen: Numbers = .{};
    const a = program(fromValue(@as(u32, 1)), pipe(.{forEach(toLeft)}));
    const b = program(fromValue(@as(u32, 2)), pipe(.{forEach(toRight)}));
    const c = program(fromValue(@as(u32, 3)), pipe(.{forEach(record)}));
    try support.run(system(.{a}), .{Left{ .seen = &left }});
    try support.run(system(.{ system(.{a}), system(.{ b, c }) }), .{ io, &seen, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 1, 1 });
    try right.expect(&.{2});
    try seen.expect(&.{3});
}

const Depot = struct { id: u32 };
const Opened = struct {
    shared: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(u32) = .init(0),
    own: std.atomic.Value(u32) = .init(0),
};

fn openShared(opened: *Opened) Depot {
    return .{ .id = 10 + opened.shared.fetchAdd(1, .seq_cst) };
}
fn closeShared(opened: *Opened, _: Depot) void {
    _ = opened.closed.fetchAdd(1, .seq_cst);
}
fn openOwn(opened: *Opened) Depot {
    _ = opened.own.fetchAdd(1, .seq_cst);
    return .{ .id = 99 };
}
fn depotToLeft(depot: Depot, sink: Left, _: u32) void {
    sink.seen.add(depot.id);
}
fn depotToRight(depot: Depot, sink: Right, _: u32) void {
    sink.seen.add(depot.id);
}

test "what a system is given replaces program defaults, and a resource among it is acquired once" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var opened: Opened = .{};
    const a = program(fromValue(@as(u32, 1)), .{forEach(depotToLeft)}).provide(.{zrx.resource(openOwn, null)});
    const b = program(fromValue(@as(u32, 2)), .{forEach(depotToRight)}).provide(.{zrx.resource(openOwn, null)});

    // By itself, a program acquires its default.
    try support.run(a, .{ Left{ .seen = &left }, &opened });
    try std.testing.expectEqual(@as(u32, 1), opened.own.load(.seq_cst));

    // In the system, both use the one depot the system was given.
    try support.run(system(.{ a, b }), .{ zrx.resource(openShared, closeShared), io, &opened, Left{ .seen = &left }, Right{ .seen = &right } });
    try left.expect(&.{ 99, 10 });
    try right.expect(&.{10});
    try std.testing.expectEqual(@as(u32, 1), opened.own.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), opened.shared.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), opened.closed.load(.seq_cst));
}

/// A value that happens to have the shape of a binding.
const Shaped = struct {
    tag: u32,

    pub const zrx_resource = {};
    pub const Provides = u64;
    pub const needs: []const type = &.{};

    pub fn bind(self: Shaped, _: anytype, next: anytype) !void {
        return next.call(@as(u64, self.tag));
    }
};

fn shape() Shaped {
    return .{ .tag = 7 };
}

fn tagToLeft(sink: Left, shaped: Shaped, _: u32) void {
    sink.seen.add(shaped.tag);
}
fn tagToRight(sink: Right, shaped: Shaped, _: u32) void {
    sink.seen.add(shaped.tag);
}

test "what a resource provides reaches the programs of a system as the value it is" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const a = program(fromValue(@as(u32, 1)), .{forEach(tagToLeft)});
    const b = program(fromValue(@as(u32, 2)), .{forEach(tagToRight)});
    const sinks = .{ Left{ .seen = &left }, Right{ .seen = &right } };

    // The resource provides a `Shaped`. A program takes it for that value...
    try support.run(a, .{zrx.resource(shape, null)} ++ sinks);
    // ...and so do the programs of a system, of one member and of two,
    // which are handed what the system resolved.
    try support.run(system(.{a}), .{zrx.resource(shape, null)} ++ sinks);
    try support.run(system(.{ a, system(.{b}) }), .{ io, zrx.resource(shape, null) } ++ sinks);
    try left.expect(&.{ 7, 7, 7 });
    try right.expect(&.{7});
}

/// A runnable that is not a zrx program: a system asks only for the mark
/// and for `run`, which is given the dependencies as a tuple.
const Custom = struct {
    pub const zrx_program = {};

    pub fn run(_: *const Custom, deps: anytype) !void {
        zrx.di.get(deps, Left).seen.add(@intCast(deps.len));
    }
};

/// The same, with declarations that happen to be named like the ones this
/// library uses for its own programs. A system must not take it for one.
const Lookalike = struct {
    pub const zrx_program = {};
    pub const zrx_own = {};

    pub fn run(_: *const Lookalike, deps: anytype) !void {
        zrx.di.get(deps, Left).seen.add(@intCast(deps.len));
    }

    pub fn runResolved(_: *const Lookalike, deps: anytype) !void {
        zrx.di.get(deps, Left).seen.add(1000);
    }
};

/// A rescue that needs nothing, for a system of several: starting tasks can
/// fail, so such a system is run with one.
fn unexpected(_: anyerror) void {
    unreachable;
}

test "a system calls a runnable's run, whatever else the runnable declares" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const b = program(fromValue(@as(u32, 2)), .{forEach(toRight)});
    system(.{Lookalike{}}).run(.{Left{ .seen = &left }});
    system(.{ Lookalike{}, b }).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right }, zrx.rescue(unexpected) });
    try left.expect(&.{ 1, 3 });
    try right.expect(&.{2});
}

test "a runnable of the caller's own is given a system's dependencies as a tuple" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const b = program(fromValue(@as(u32, 2)), .{forEach(toRight)});
    system(.{Custom{}}).run(.{Left{ .seen = &left }});
    system(.{ Custom{}, b }).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right }, zrx.rescue(unexpected) });
    // What it counted: one dependency, then three. A rescue is not one.
    try left.expect(&.{ 1, 3 });
    try right.expect(&.{2});
}

/// Two runnables that say exactly what they are given. They run at the same
/// time in a system of two, so each writes to a log of its own.
const ExactLeft = struct {
    pub const zrx_program = {};

    pub fn run(_: *const ExactLeft, deps: struct { std.Io, Left, Right }) void {
        deps[1].seen.add(7);
    }
};
const ExactRight = struct {
    pub const zrx_program = {};

    pub fn run(_: *const ExactRight, deps: struct { std.Io, Left, Right }) void {
        deps[2].seen.add(8);
    }
};

test "a runnable that names its dependencies is given those and nothing else, with or without a rescue" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const sinks = .{ Left{ .seen = &left }, Right{ .seen = &right } };
    system(.{ExactLeft{}}).run(.{io} ++ sinks);
    system(.{ExactLeft{}}).run(.{io} ++ sinks ++ .{zrx.rescue(unexpected)});
    system(.{ ExactLeft{}, ExactRight{} }).run(.{io} ++ sinks ++ .{zrx.rescue(unexpected)});
    try left.expect(&.{ 7, 7, 7 });
    try right.expect(&.{8});
}

fn patiently(clock: std.Io, out: anytype) !void {
    var value: u32 = 0;
    while (value < 200) : (value += 1) {
        try clock.sleep(.fromMilliseconds(1), .awake);
        if (try out.push(value) == .done) return;
    }
}

test "the first failure in a system is returned" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const failing = program(range(u32, 0, 10), pipe(.{ map(failAtTwo), forEach(toLeft) }));
    const slow = program(fromProducer(u32, patiently), pipe(.{forEach(toRight)}));
    const result = support.run(system(.{ failing, slow }), .{ io, Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.Two, result);
    try left.expect(&.{ 0, 1 });
}

/// What a rescue was called with, and how often. One for a program and one
/// for the system it is in: they are called on different tasks.
const Failure = struct { err: ?anyerror = null, calls: u32 = 0 };
const SystemFailure = struct { err: ?anyerror = null, calls: u32 = 0 };

fn noteFailure(failure: *Failure, err: anyerror) void {
    failure.err = err;
    failure.calls += 1;
}
fn noteSystemFailure(failure: *SystemFailure, err: anyerror) void {
    failure.err = err;
    failure.calls += 1;
}

test "a rescue takes a failure from beyond a queue" {
    var left: Numbers = .{};
    var failure: Failure = .{};
    const queued = program(range(u32, 0, 10), pipe(.{ queue(2), map(failAtTwo), forEach(toLeft) }));
    queued.run(.{ io, Left{ .seen = &left }, &failure, zrx.rescue(noteFailure) });
    try std.testing.expectEqual(Failure{ .err = error.Two, .calls = 1 }, failure);
    try left.expect(&.{ 0, 1 });
}

/// Names every error it can be given. A program with a task boundary can be
/// cancelled and can find that tasks cannot be started: both are among them.
fn noteQueued(failure: *Failure, err: anytype) void {
    failure.err = switch (err) {
        error.Two => error.Two,
        error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
        error.Canceled => error.Canceled,
    };
    failure.calls += 1;
}

test "a rescue of a program with a task boundary is given exactly its errors" {
    var left: Numbers = .{};
    var failure: Failure = .{};
    const queued = program(range(u32, 0, 10), pipe(.{ queue(2), map(failAtTwo), forEach(toLeft) }));
    queued.run(.{ io, Left{ .seen = &left }, &failure, zrx.rescue(noteQueued) });
    try std.testing.expectEqual(Failure{ .err = error.Two, .calls = 1 }, failure);
}

test "a system's rescue takes the failure of a member, in place of the member's own" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var member: Failure = .{};
    var whole: SystemFailure = .{};
    const failing = program(range(u32, 0, 10), pipe(.{ map(failAtTwo), forEach(toLeft) })).provide(.{zrx.rescue(noteFailure)});
    const slow = program(fromProducer(u32, patiently), pipe(.{forEach(toRight)}));
    system(.{ failing, slow }).run(.{ io, Left{ .seen = &left }, Right{ .seen = &right }, &member, &whole, zrx.rescue(noteSystemFailure) });
    // What the system is given replaces a member's default: the failure
    // ended the system, and the system's rescue was given it.
    try std.testing.expectEqual(SystemFailure{ .err = error.Two, .calls = 1 }, whole);
    try std.testing.expectEqual(Failure{}, member);
    try left.expect(&.{ 0, 1 });
}

test "a system of one program leaves the failure to that program's rescue" {
    var left: Numbers = .{};
    var member: Failure = .{};
    const failing = program(range(u32, 0, 10), pipe(.{ map(failAtTwo), forEach(toLeft) })).provide(.{zrx.rescue(noteFailure)});
    // Nothing is left for the system to fail with: this compiles without a
    // rescue of its own.
    system(.{failing}).run(.{ Left{ .seen = &left }, &member });
    try std.testing.expectEqual(Failure{ .err = error.Two, .calls = 1 }, member);
    try left.expect(&.{ 0, 1 });
}

test "what a run can fail with is exactly what its parts can" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    const queued = program(range(u32, 0, 4), pipe(.{ queue(2), map(failAtTwo), forEach(toLeft) }));
    const workers = program(range(u32, 0, 4), .{ zrx.concurrent(2, .{map(failAtTwo)}), forEach(toLeft) });
    const plain = program(range(u32, 0, 2), pipe(.{forEach(toRight)}));
    const deps = .{ io, Left{ .seen = &left }, Right{ .seen = &right } };

    // A task boundary adds a cancellation and tasks that cannot be started.
    inline for (.{ queued, workers, system(.{ queued, plain }) }) |failing| {
        const rest = support.runLeft(failing, deps);
        try std.testing.expectEqualStrings("Canceled ConcurrencyUnavailable Two ", rest.names());
        try std.testing.expectEqual(error.Two, rest.err.?);
    }

    // Nothing can fail here: this compiles without a rescue.
    plain.run(deps);
}

// --- supervision ------------------------------------------------------------
//
// Nothing here measures time. A party that should be interrupted waits far
// longer than a test should take and records whether it woke by itself.

const Idle = struct {
    /// Producers that have begun to wait.
    waiting: std.atomic.Value(usize) = .init(0),
    woke_by_itself: std.atomic.Value(bool) = .init(false),
};

fn idleThenPush(clock: std.Io, idle: *Idle, out: anytype) !void {
    _ = idle.waiting.fetchAdd(1, .seq_cst);
    try clock.sleep(.fromSeconds(5), .awake);
    idle.woke_by_itself.store(true, .seq_cst);
    _ = try out.push(@as(u32, 2));
}

fn idleProgram() @TypeOf(program(fromProducer(u32, idleThenPush), pipe(.{forEach(toRight)}))) {
    return program(fromProducer(u32, idleThenPush), pipe(.{forEach(toRight)}));
}

test "merge cancels a source that is not pushing once the pipe is done" {
    var seen: Numbers = .{};
    var idle: Idle = .{};
    const first = merge(.{ fromValue(@as(u32, 7)), fromProducer(u32, idleThenPush) });
    try support.run(program(first, pipe(.{ take(1), forEach(record) })), .{ io, &seen, &idle });
    const second = merge(.{ fromProducer(u32, idleThenPush), fromValue(@as(u32, 8)) });
    try support.run(program(second, pipe(.{ take(1), forEach(record) })), .{ io, &seen, &idle });
    try seen.expect(&.{ 7, 8 });
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "merge cancels a source that is not pushing once another source's push fails" {
    var seen: Numbers = .{};
    var idle: Idle = .{};
    const sources = merge(.{ fromValue(@as(u32, 2)), fromProducer(u32, idleThenPush) });
    const result = support.run(program(sources, pipe(.{ map(failAtTwo), forEach(record) })), .{ io, &seen, &idle });
    try std.testing.expectError(error.Two, result);
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "a system returns a failure while another program is waiting" {
    var left: Numbers = .{};
    var right: Numbers = .{};
    var idle: Idle = .{};
    const failing = program(fromValue(@as(u32, 2)), pipe(.{ map(failAtTwo), forEach(toLeft) }));
    const deps = .{ io, &idle, Left{ .seen = &left }, Right{ .seen = &right } };
    try std.testing.expectError(error.Two, support.run(system(.{ failing, idleProgram() }), deps));
    try std.testing.expectError(error.Two, support.run(system(.{ idleProgram(), failing }), deps));
    try std.testing.expectError(error.Two, support.run(system(.{ idleProgram(), failing, idleProgram() }), deps));
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "members never run on the supervising task, however busy the async pool is" {
    // With no async capacity, `Io.async` would run a member on the caller,
    // which then could not see the other one fail.
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .nothing });
    defer backend.deinit();
    var left: Numbers = .{};
    var right: Numbers = .{};
    var idle: Idle = .{};
    const failing = program(fromValue(@as(u32, 2)), pipe(.{ map(failAtTwo), forEach(toLeft) }));
    const deps = .{ backend.io(), &idle, Left{ .seen = &left }, Right{ .seen = &right } };
    try std.testing.expectError(error.Two, support.run(system(.{ idleProgram(), failing }), deps));

    var seen: Numbers = .{};
    const sources = merge(.{ fromProducer(u32, idleThenPush), fromValue(@as(u32, 7)) });
    try support.run(program(sources, pipe(.{ take(1), forEach(record) })), .{ backend.io(), &seen, &idle });
    try seen.expect(&.{7});
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "without concurrency, a system and a merge fail before anything runs" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    var left: Numbers = .{};
    var right: Numbers = .{};
    const a = program(fromValue(@as(u32, 1)), pipe(.{forEach(toLeft)}));
    const b = program(fromValue(@as(u32, 2)), pipe(.{forEach(toRight)}));
    const together = support.run(system(.{ a, b }), .{ backend.io(), Left{ .seen = &left }, Right{ .seen = &right } });
    try std.testing.expectError(error.ConcurrencyUnavailable, together);
    try left.expect(&.{});
    try right.expect(&.{});

    var seen: Numbers = .{};
    const merged = program(merge(.{ fromValue(@as(u32, 1)), fromValue(@as(u32, 2)) }), pipe(.{forEach(record)}));
    try std.testing.expectError(error.ConcurrencyUnavailable, support.run(merged, .{ backend.io(), &seen }));
    try seen.expect(&.{});
}

test "running out of concurrency part-way cancels the members already started" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var right: Numbers = .{};
    var idle: Idle = .{};
    const result = support.run(system(.{ idleProgram(), idleProgram() }), .{ backend.io(), &idle, Right{ .seen = &right } });
    try std.testing.expectError(error.ConcurrencyUnavailable, result);
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}

test "cancelling the caller cancels every member" {
    var right: Numbers = .{};
    var idle: Idle = .{};
    const both = system(.{ idleProgram(), idleProgram() });
    const Both = @TypeOf(both);
    const Deps = struct { std.Io, *Idle, Right };
    const Caller = struct {
        fn run(members: *const Both, deps: Deps) ?anyerror {
            support.run(members, deps) catch |err| return err;
            return null;
        }
    };
    var caller = try io.concurrent(Caller.run, .{ &both, Deps{ io, &idle, Right{ .seen = &right } } });
    // Both members are waiting, so the caller is past starting them.
    while (idle.waiting.load(.seq_cst) < 2) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), caller.cancel(io));
    try std.testing.expect(!idle.woke_by_itself.load(.seq_cst));
}
