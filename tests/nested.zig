//! Sub-pipes within one item: `each` and `attempt`.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromProducer = zrx.fromProducer;
const range = zrx.range;
const map = zrx.map;
const tap = zrx.tap;
const fold = zrx.fold;
const take = zrx.take;
const flatten = zrx.flatten;
const recover = zrx.recover;
const Failed = zrx.Failed;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const forEach = zrx.forEach;
const field = zrx.field;
const each = zrx.each;
const attempt = zrx.attempt;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

const Pair = zrx.Tagged(u32, u32);
const Pairs = support.Recorder(Pair);
const recordPair = support.record(Pair);

const Range = @TypeOf(range(u32, 0, 0));

/// The numbers below `n`.
fn below(n: u32) Range {
    return range(u32, 0, n);
}
fn add(sum: u32, value: u32) u32 {
    return sum + value;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn double(value: u32) u32 {
    return value * 2;
}

const Pulls = struct { count: usize = 0 };
fn countPull(pulls: *Pulls, _: u32) void {
    pulls.count += 1;
}

/// How often a `Counted` stage was constructed, pushed to and finished.
const Lives = struct { made: usize = 0, pushed: usize = 0, finished: usize = 0 };

/// Passes every item on and counts its own hooks in `*Lives`.
const Counted = struct {
    pub const zrx_operator = {};
    pub const name = "counted";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            lives: *Lives,

            pub fn init(self: *@This(), _: *const Counted, env: Env) void {
                self.lives = zrx.di.get(env, *Lives);
                self.lives.made += 1;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.lives.pushed += 1;
                return down.push(item);
            }

            pub fn finish(self: *@This(), _: anytype) !void {
                self.lives.finished += 1;
            }
        };
    }
};

// --- each -------------------------------------------------------------------

test "each runs a fresh sub-pipe over the source made from every item" {
    var seen: Pairs = .{};
    var lives: Lives = .{};
    const sums = pipe(.{
        each(below, .{ Counted{}, fold(@as(u32, 0), add) }),
        forEach(recordPair),
    });
    try support.run(program(range(u32, 0, 5), sums), .{ &seen, &lives });
    // One value per item, the seed for the item whose source is empty.
    try seen.expect(&.{
        .{ .source = 0, .item = 0 },
        .{ .source = 1, .item = 0 },
        .{ .source = 2, .item = 1 },
        .{ .source = 3, .item = 3 },
        .{ .source = 4, .item = 6 },
    });
    try std.testing.expectEqual(Lives{ .made = 5, .pushed = 10, .finished = 5 }, lives);
}

test "a sub-pipe that is done ends its item, not the stream" {
    var seen: Pairs = .{};
    var lives: Lives = .{};
    const firstTwo = pipe(.{
        each(below, .{ Counted{}, take(2), fold(@as(u32, 0), add) }),
        forEach(recordPair),
    });
    try support.run(program(range(u32, 1, 5), firstTwo), .{ &seen, &lives });
    try seen.expect(&.{
        .{ .source = 1, .item = 0 },
        .{ .source = 2, .item = 1 },
        .{ .source = 3, .item = 1 },
        .{ .source = 4, .item = 1 },
    });
    // Every item gets a `take(2)` of its own, and its source stops there.
    try std.testing.expectEqual(Lives{ .made = 4, .pushed = 7, .finished = 4 }, lives);
}

test "once the pipe after each is done, the item's source stops and so does the stream" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    var lives: Lives = .{};
    const work = pipe(.{
        tap(countPull),
        each(below, .{Counted{}}),
        map(field(.item)),
        take(4),
        forEach(record),
    });
    // 3 gives 0, 1, 2. The fourth value is the first of the next item, whose
    // stream is cut short there and whose sub-pipe is still finished.
    try support.run(program(range(u32, 3, 1000), work), .{ &seen, &pulls, &lives });
    try seen.expect(&.{ 0, 1, 2, 0 });
    try std.testing.expectEqual(@as(usize, 2), pulls.count);
    try std.testing.expectEqual(Lives{ .made = 2, .pushed = 4, .finished = 2 }, lives);
}

const Letters = @TypeOf(fromSlice(@as([]const u8, "")));
const Sized = zrx.Tagged([]const u8, usize);

fn letters(word: []const u8) Letters {
    return fromSlice(word);
}
fn lettersOfAny(word: anytype) Letters {
    return fromSlice(word);
}
fn count(n: usize, _: u8) usize {
    return n + 1;
}
fn describe(writer: *std.Io.Writer, sized: Sized) !void {
    try writer.print("{s}={d};", .{ sized.source, sized.item });
}
fn describeTerminated(writer: *std.Io.Writer, sized: zrx.Tagged([:0]const u8, usize)) !void {
    try writer.print("{s}:{d};", .{ sized.source, sized.item });
}

test "the tag has the type source_of declares, whichever kind of slice the item is" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const terminated = [_][:0]const u8{ "ab", "", "cde" };
    const plain = [_][]const u8{"xy"};
    // One pipe, written for `[]const u8`, takes both.
    const sized = pipe(.{
        each(letters, .{fold(@as(usize, 0), count)}),
        forEach(describe),
    });
    try support.run(program(fromSlice(&terminated), sized), .{&writer});
    try support.run(program(fromSlice(&plain), sized), .{&writer});
    // A generic `source_of` declares nothing: the tag is the item as it came.
    const asItCame = pipe(.{
        each(lettersOfAny, .{fold(@as(usize, 0), count)}),
        forEach(describeTerminated),
    });
    try support.run(program(fromSlice(&terminated), asItCame), .{&writer});
    try std.testing.expectEqualStrings("ab=2;=0;cde=3;xy=2;ab:2;:0;cde:3;", writer.buffered());
}

const Limit = struct { below: u32 };

fn limited(limit: Limit, n: u32) error{TooMany}!Range {
    if (n >= limit.below) return error.TooMany;
    return range(u32, 0, n);
}

test "source_of takes dependencies, and when it fails no sub-pipe is made for the item" {
    var seen: Pairs = .{};
    var lives: Lives = .{};
    const sums = pipe(.{
        each(limited, .{ Counted{}, fold(@as(u32, 0), add) }),
        forEach(recordPair),
    });
    const result = support.run(program(range(u32, 1, 5), sums), .{ &seen, &lives, Limit{ .below = 3 } });
    try std.testing.expectError(error.TooMany, result);
    try seen.expect(&.{ .{ .source = 1, .item = 0 }, .{ .source = 2, .item = 1 } });
    try std.testing.expectEqual(Lives{ .made = 2, .pushed = 3, .finished = 2 }, lives);
}

fn failAtTwo(value: u32) error{Two}!u32 {
    if (value == 2) return error.Two;
    return value;
}

test "a failure in the sub-pipe fails the run, and that item's sub-pipe is not finished" {
    var seen: Pairs = .{};
    var lives: Lives = .{};
    const sums = pipe(.{
        each(below, .{ Counted{}, map(failAtTwo), fold(@as(u32, 0), add) }),
        forEach(recordPair),
    });
    const result = support.run(program(range(u32, 1, 5), sums), .{ &seen, &lives });
    try std.testing.expectError(error.Two, result);
    try seen.expect(&.{ .{ .source = 1, .item = 0 }, .{ .source = 2, .item = 1 } });
    // The third item's stream reached its third value.
    try std.testing.expectEqual(Lives{ .made = 3, .pushed = 6, .finished = 2 }, lives);
}

test "sub-pipes nest" {
    var seen: Pairs = .{};
    // For n: the sum, over every k below n, of the numbers below k.
    const inner = pipe(.{
        each(below, .{fold(@as(u32, 0), add)}),
        map(field(.item)),
        fold(@as(u32, 0), add),
    });
    try support.run(program(range(u32, 3, 5), .{ each(below, inner), forEach(recordPair) }), .{&seen});
    try seen.expect(&.{ .{ .source = 3, .item = 1 }, .{ .source = 4, .item = 4 } });
}

test "each works in a case of a route, where stages are stored together" {
    var seen: Numbers = .{};
    const work = pipe(.{
        route(.{
            when(isEven, .{
                each(below, .{fold(@as(u32, 0), add)}),
                map(field(.item)),
            }),
            otherwise(.{map(double)}),
        }),
        forEach(record),
    });
    try support.run(program(range(u32, 3, 7), work), .{&seen});
    try seen.expect(&.{ 6, 6, 10, 15 });
}

const Ticks = @TypeOf(fromProducer(u32, threeTicks));

/// A producer that asks for `Stop`, as one of a program may.
fn threeTicks(stop: zrx.Stop, out: anytype) !void {
    var tick: u32 = 0;
    while (tick < 3 and !stop.requested()) : (tick += 1) {
        if (try out.push(tick) == .done) return;
    }
}
fn ticksOf(_: u32) Ticks {
    return fromProducer(u32, threeTicks);
}

test "the item's source may be any source, also a producer that asks for Stop" {
    var seen: Pairs = .{};
    try support.run(program(range(u32, 7, 9), .{ each(ticksOf, .{fold(@as(u32, 0), add)}), forEach(recordPair) }), .{&seen});
    try seen.expect(&.{ .{ .source = 7, .item = 3 }, .{ .source = 8, .item = 3 } });
}

// --- attempt ----------------------------------------------------------------

const ParseError = error{ Odd, TooBig };

fn evenOnly(value: u32) ParseError!u32 {
    if (value > 100) return error.TooBig;
    if (value % 2 == 1) return error.Odd;
    return value;
}

const Fallbacks = struct { count: usize = 0 };

fn plusHundred(fallbacks: *Fallbacks, failed: Failed(ParseError, u32)) u32 {
    std.debug.assert(failed.err == error.Odd);
    fallbacks.count += 1;
    return failed.item + 100;
}
/// The error path most tests here use: an odd item, a hundred higher.
const raised = pipe(.{map(plusHundred)});

test "attempt emits what its error path makes of an item its sub-pipe fails on" {
    var seen: Numbers = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{
            map(evenOnly),
            map(double),
        }, ParseError, raised),
        forEach(record),
    });
    try support.run(program(range(u32, 0, 6), work), .{ &seen, &fallbacks });
    try seen.expect(&.{ 0, 101, 4, 103, 8, 105 });
    try std.testing.expectEqual(@as(usize, 3), fallbacks.count);
}

/// The path is given the error set the `attempt` names, whatever the
/// sub-pipe's own is.
fn anyPlusHundred(failed: anytype) u32 {
    return failed.item + 100;
}
fn giveUpOnTooBig(failed: Failed(ParseError, u32)) error{GaveUp}!u32 {
    return if (failed.err == error.TooBig) error.GaveUp else failed.item + 100;
}

test "what an attempt takes is no longer among the errors of the run, and what its path fails with is" {
    var seen: Numbers = .{};
    const values = [_]u32{ 2, 3, 500, 4 };
    const deps = .{&seen};
    inline for (.{ anyerror, ParseError }) |Taken| {
        // Nothing is left: this compiles without a rescue.
        program(fromSlice(&values), .{ attempt(.{map(evenOnly)}, Taken, .{map(anyPlusHundred)}), forEach(record) }).run(deps);
    }
    try seen.expect(&.{ 2, 103, 600, 4, 2, 103, 600, 4 });

    // A path that fails adds its own errors, and fails the run with them.
    const strict = program(fromSlice(&values), .{ attempt(.{map(evenOnly)}, ParseError, .{map(giveUpOnTooBig)}), forEach(record) });
    const left = support.runLeft(strict, deps);
    try std.testing.expectEqualStrings("GaveUp ", left.names());
    try std.testing.expectEqual(error.GaveUp, left.err.?);
    try seen.expect(&.{ 2, 103, 600, 4, 2, 103, 600, 4, 2, 103 });
}

test "attempt with an error set lets other errors through" {
    var seen: Numbers = .{};
    const values = [_]u32{ 2, 3, 500, 4 };
    const odd = program(fromSlice(&values), .{ attempt(.{map(evenOnly)}, error{Odd}, .{map(anyPlusHundred)}), forEach(record) });
    const left = support.runLeft(odd, .{&seen});
    try std.testing.expectEqualStrings("TooBig ", left.names());
    try std.testing.expectEqual(error.TooBig, left.err.?);
    try seen.expect(&.{ 2, 103 });
}

/// Fails with anything: nothing is known about its errors where it is attempted.
fn loose(value: u32) anyerror!u32 {
    return switch (value) {
        1 => error.Odd,
        3 => error.TooBig,
        5 => error.Canceled,
        else => value,
    };
}

test "attempt selects what it takes also where any error is possible" {
    var seen: Numbers = .{};
    const some = program(range(u32, 0, 8), .{ attempt(.{map(loose)}, error{Odd}, .{map(anyPlusHundred)}), forEach(record) });
    try std.testing.expectError(error.TooBig, support.run(some, .{&seen}));
    try seen.expect(&.{ 0, 101, 2 });

    seen = .{};
    const every = program(range(u32, 0, 8), .{ attempt(.{map(loose)}, anyerror, .{map(anyPlusHundred)}), forEach(record) });
    try std.testing.expectError(error.Canceled, support.run(every, .{&seen}));
    try seen.expect(&.{ 0, 101, 2, 103, 4 });
}

fn failedItem(failed: Failed(ParseError, u32)) u32 {
    return failed.item;
}

test "an error path of an attempt has state and an end of the stream of its own" {
    var seen: Numbers = .{};
    const summed = pipe(.{ map(failedItem), fold(@as(u32, 0), add) });
    try support.run(program(range(u32, 0, 6), .{ attempt(.{map(evenOnly)}, ParseError, summed), forEach(record) }), .{&seen});
    // Nothing in place of 1, 3 and 5; their sum once, when the stream ends.
    try seen.expect(&.{ 0, 2, 4, 9 });
}

fn failAbove100(value: u32) error{Odd}!u32 {
    if (value > 100) return error.Odd;
    return value;
}

test "a failure of the pipe after an attempt, for what the error path emitted, passes through" {
    var seen: Numbers = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{map(evenOnly)}, ParseError, raised),
        map(failAbove100),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 10), work), .{ &seen, &fallbacks });
    // 1 became 101, which fails after the attempt, with an error by the
    // name the attempt takes: the path is not asked a second time.
    try std.testing.expectError(error.Odd, result);
    try seen.expect(&.{0});
    try std.testing.expectEqual(@as(usize, 1), fallbacks.count);
}

fn pair(value: u32) [2]u32 {
    return .{ value, value + 10 };
}
fn failAtTwelve(value: u32) error{Twelve}!u32 {
    if (value == 12) return error.Twelve;
    return value;
}
fn nine(_: Failed(error{Twelve}, u32)) u32 {
    return 9;
}

test "what the sub-pipe had emitted for the item is not taken back" {
    var seen: Numbers = .{};
    const work = pipe(.{
        attempt(.{
            map(pair),
            flatten(),
            map(failAtTwelve),
        }, error{Twelve}, .{map(nine)}),
        forEach(record),
    });
    try support.run(program(range(u32, 1, 4), work), .{&seen});
    // 2 gives 2 and then fails on 12.
    try seen.expect(&.{ 1, 11, 2, 9, 3, 13 });
}

/// Fails as `evenOnly` does, by name.
fn oddAtFour(value: u32) error{Odd}!u32 {
    if (value == 4) return error.Odd;
    return value;
}

test "a failure of the pipe after an attempt passes through, whatever its name" {
    var seen: Numbers = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{map(evenOnly)}, ParseError, raised),
        map(oddAtFour),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 10), work), .{ &seen, &fallbacks });
    try std.testing.expectError(error.Odd, result);
    try seen.expect(&.{ 0, 101, 2, 103 });
    // The fallback was asked about 1 and 3, not about 4.
    try std.testing.expectEqual(@as(usize, 2), fallbacks.count);
}

const Rejected = struct { seen: *Numbers };
fn reject(log: Rejected, failed: anytype) void {
    log.seen.add(failed.item);
}
fn failAlways(_: u32) error{Ended}!u32 {
    return error.Ended;
}

test "a recover inside the sub-pipe does not see a failure of the pipe after the attempt" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{
            // It would take the failure after the attempt, if it saw it. It
            // leaves `TooBig` to the fallback: a sub-pipe that cannot fail
            // has nothing to attempt.
            recover(error{ Odd, Ended }, .{forEach(reject)}),
            map(evenOnly),
        }, ParseError, raised),
        map(failAlways),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 10), work), .{ &seen, &fallbacks, Rejected{ .seen = &rejected } });
    try std.testing.expectError(error.Ended, result);
    try rejected.expect(&.{});
    try std.testing.expectEqual(@as(usize, 0), fallbacks.count);
}

/// A stage that does not keep to the contract: it pushes every item twice,
/// whatever it is answered, and fails when it is answered `.done`.
const Insistent = struct {
    pub const zrx_operator = {};
    pub const name = "insistent";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime _: type, comptime In: type) type {
        return struct {
            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                _ = try down.push(item);
                if (try down.push(item) == .done) return error.Refused;
                return .more;
            }
        };
    }
};

fn countThenFail(pulls: *Pulls, _: u32) error{Ended}!u32 {
    pulls.count += 1;
    return error.Ended;
}
fn refused(fallbacks: *Fallbacks, failed: Failed(error{Refused}, u32)) u32 {
    fallbacks.count += 1;
    return failed.item;
}

test "once the pipe after an attempt has failed, it is not pushed to again and its failure is the one returned" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{Insistent{}}, error{Refused}, .{map(refused)}),
        map(countThenFail),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 10), work), .{ &seen, &pulls, &fallbacks });
    // The sub-pipe pushed again and then failed by itself: neither reaches
    // the pipe that had failed, as a second push or as a fallback.
    try std.testing.expectError(error.Ended, result);
    try std.testing.expectEqual(@as(usize, 1), pulls.count);
    try std.testing.expectEqual(@as(usize, 0), fallbacks.count);
}

fn neverOdd(value: u32) error{Odd}!u32 {
    return value;
}

test "when the pipe after an attempt fails, the sub-pipe is told that nothing more is wanted" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{
            map(pair),
            flatten(),
            tap(countPull),
            map(neverOdd),
        }, ParseError, raised),
        map(failAlways),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 10), work), .{ &seen, &pulls, &fallbacks });
    try std.testing.expectError(error.Ended, result);
    // The first of the item's two values failed after the attempt: the
    // second was not sent through the sub-pipe.
    try std.testing.expectEqual(@as(usize, 1), pulls.count);
    try std.testing.expectEqual(@as(usize, 0), fallbacks.count);
}

fn interrupted(value: u32) error{ Canceled, Odd }!u32 {
    if (value == 2) return error.Canceled;
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn countOdd(fallbacks: *Fallbacks, _: anytype) u32 {
    fallbacks.count += 1;
    return 0;
}

test "attempt falls back from failures but never from a cancellation" {
    inline for (.{ anyerror, error{ Canceled, Odd } }) |Taken| {
        var seen: Numbers = .{};
        var fallbacks: Fallbacks = .{};
        const result = support.run(program(range(u32, 0, 5), .{ attempt(.{map(interrupted)}, Taken, .{map(countOdd)}), forEach(record) }), .{ &seen, &fallbacks });
        try std.testing.expectError(error.Canceled, result);
        try seen.expect(&.{ 0, 0 });
        try std.testing.expectEqual(@as(usize, 1), fallbacks.count);
    }
}

fn late(_: u32) error{Late}!u32 {
    return error.Late;
}
fn lateFallback(fallbacks: *Fallbacks, failed: Failed(anyerror, u32)) u32 {
    fallbacks.count += 1;
    return failed.item + 100;
}

test "an attempt keeps the sub-pipe's state across items and finishes it with the stream" {
    var seen: Numbers = .{};
    var lives: Lives = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{
            Counted{},
            map(evenOnly),
            fold(@as(u32, 0), add),
        }, ParseError, raised),
        forEach(record),
    });
    try support.run(program(range(u32, 0, 5), work), .{ &seen, &lives, &fallbacks });
    // The fallbacks as the items fail, then the one fold over the rest.
    try seen.expect(&.{ 101, 103, 6 });
    try std.testing.expectEqual(Lives{ .made = 1, .pushed = 5, .finished = 1 }, lives);
}

test "a failure of the sub-pipe's own end of stream is not an item's" {
    var seen: Numbers = .{};
    var fallbacks: Fallbacks = .{};
    const work = pipe(.{
        attempt(.{
            map(evenOnly),
            fold(@as(u32, 0), add),
            map(late),
        }, anyerror, .{map(lateFallback)}),
        forEach(record),
    });
    const result = support.run(program(range(u32, 0, 3), work), .{ &seen, &fallbacks });
    try std.testing.expectError(error.Late, result);
    try seen.expect(&.{101});
    try std.testing.expectEqual(@as(usize, 1), fallbacks.count);
}

test "done passes through an attempt, from the pipe after it and from the sub-pipe" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    var fallbacks: Fallbacks = .{};
    const after = pipe(.{
        tap(countPull),
        attempt(.{map(evenOnly)}, ParseError, raised),
        take(2),
        forEach(record),
    });
    try support.run(program(range(u32, 0, 1000), after), .{ &seen, &pulls, &fallbacks });
    try seen.expect(&.{ 0, 101 });
    try std.testing.expectEqual(@as(usize, 2), pulls.count);

    const inside = pipe(.{
        tap(countPull),
        attempt(.{
            take(3),
            map(evenOnly),
        }, ParseError, raised),
        forEach(record),
    });
    try support.run(program(range(u32, 0, 1000), inside), .{ &seen, &pulls, &fallbacks });
    try seen.expect(&.{ 0, 101, 0, 101, 2 });
    try std.testing.expectEqual(@as(usize, 5), pulls.count);

    // And from the error path: the first failure is the last item.
    const once = pipe(.{
        tap(countPull),
        attempt(.{map(evenOnly)}, ParseError, .{ take(1), map(plusHundred) }),
        forEach(record),
    });
    try support.run(program(range(u32, 0, 1000), once), .{ &seen, &pulls, &fallbacks });
    try seen.expect(&.{ 0, 101, 0, 101, 2, 0, 101 });
    try std.testing.expectEqual(@as(usize, 7), pulls.count);
}

test "attempt around each: an item whose source or sub-pipe fails becomes one value" {
    var seen: Pairs = .{};
    var lives: Lives = .{};
    const sums = pipe(.{
        attempt(.{
            each(limited, .{ Counted{}, map(failAtTwo), fold(@as(u32, 0), add) }),
        }, error{ TooMany, Two }, .{map(unsummed)}),
        forEach(recordPair),
    });
    try support.run(program(range(u32, 1, 6), sums), .{ &seen, &lives, Limit{ .below = 4 } });
    try seen.expect(&.{
        .{ .source = 1, .item = 0 },
        .{ .source = 2, .item = 1 },
        .{ .source = 3, .item = 999 }, // its third value failed
        .{ .source = 4, .item = 999 }, // no source for it
        .{ .source = 5, .item = 999 },
    });
    // The sub-pipe of an item that failed is not finished.
    try std.testing.expectEqual(Lives{ .made = 3, .pushed = 6, .finished = 2 }, lives);
}

fn unsummed(failed: Failed(error{ TooMany, Two }, u32)) Pair {
    return .{ .source = failed.item, .item = 999 };
}
