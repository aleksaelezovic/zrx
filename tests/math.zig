//! `zrx.ext.math`: arithmetic on items, reducers and `Stats`.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const range = zrx.range;
const map = zrx.map;
const scan = zrx.scan;
const fold = zrx.fold;
const batch = zrx.batch;
const recover = zrx.recover;
const attempt = zrx.attempt;
const forEach = zrx.forEach;
const reduce = zrx.reduce;
const orElse = zrx.orElse;
const compose = zrx.compose;
const field = zrx.field;
const math = zrx.ext.math;
const checked = math.checked;

/// A recorder and the handler that fills it, for items of type `T`. The
/// handler takes that type only: what a pipe emits is checked by the compiler.
fn Seen(comptime T: type) type {
    return support.Recorder(T);
}
fn seenAs(comptime T: type) fn (*Seen(T), T) void {
    return support.record(T);
}

fn signed(value: u32) i32 {
    return @as(i32, @intCast(value)) - 4;
}
fn halves(value: u32) f64 {
    return @as(f64, @floatFromInt(value)) / 2;
}

// --- transforms ---------------------------------------------------------------

test "each transform changes an unsigned item as its operator does" {
    var seen: Seen(u32) = .{};
    const deps = .{&seen};
    const out = forEach(seenAs(u32));
    try support.run(program(range(u32, 5, 8), .{ map(math.add(3)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.sub(5)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.mul(4)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.div(2)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.mod(3)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.pow(2)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.clamp(6, 6)), out }), deps);
    try support.run(program(range(u32, 5, 8), .{ map(math.abs), out }), deps);
    try seen.expect(&.{
        8,  9,  10,
        0,  1,  2,
        20, 24, 28,
        2,  3,  3,
        2,  0,  1,
        25, 36, 49,
        6,  6,  6,
        5,  6,  7,
    });
}

test "for a signed item div rounds toward zero, mod is never negative, and abs is unsigned" {
    var seen: Seen(i32) = .{};
    // -4 .. 3
    const numbers = pipe(.{map(signed)});
    try support.run(program(range(u32, 0, 8), .{ numbers, map(math.div(3)), forEach(seenAs(i32)) }), .{&seen});
    try support.run(program(range(u32, 0, 8), .{ numbers, map(math.mod(3)), forEach(seenAs(i32)) }), .{&seen});
    try support.run(program(range(u32, 0, 8), .{ numbers, map(math.neg), forEach(seenAs(i32)) }), .{&seen});
    try support.run(program(range(u32, 0, 8), .{ numbers, map(math.div(-2)), forEach(seenAs(i32)) }), .{&seen});
    try support.run(program(range(u32, 0, 8), .{ numbers, map(math.clamp(-2, 1)), forEach(seenAs(i32)) }), .{&seen});
    try seen.expect(&.{
        -1, -1, 0,  0,  0, 0,  0,  1,
        2,  0,  1,  2,  0, 1,  2,  0,
        4,  3,  2,  1,  0, -1, -2, -3,
        2,  1,  1,  0,  0, 0,  -1, -1,
        -2, -2, -2, -1, 0, 1,  1,  1,
    });

    // The smallest value has a distance from zero too: nothing overflows.
    var far: Seen(u32) = .{};
    const edges = [_]i32{ std.math.minInt(i32), -1, 0, std.math.maxInt(i32) };
    try support.run(program(fromSlice(&edges), .{ map(math.abs), forEach(seenAs(u32)) }), .{&far});
    try far.expect(&.{ 1 << 31, 1, 0, (1 << 31) - 1 });
}

test "for a float div divides, and every transform keeps the float" {
    var seen: Seen(f64) = .{};
    const out = forEach(seenAs(f64));
    // 0, 0.5, 1, 1.5
    const numbers = pipe(.{map(halves)});
    try support.run(program(range(u32, 0, 4), .{ numbers, map(math.div(2)), out }), .{&seen});
    try support.run(program(range(u32, 0, 4), .{ numbers, map(math.add(0.25)), map(math.sub(1)), map(math.mul(-2)), out }), .{&seen});
    try support.run(program(range(u32, 0, 4), .{ numbers, map(math.pow(3)), out }), .{&seen});
    try support.run(program(range(u32, 0, 4), .{ numbers, map(math.neg), map(math.abs), map(math.clamp(0.25, 1)), out }), .{&seen});
    try support.run(program(range(u32, 0, 4), .{ numbers, map(math.neg), map(math.mod(1)), out }), .{&seen});
    try seen.expect(&.{
        0,    0.25,  0.5,  0.75,
        1.5,  0.5,   -0.5, -1.5,
        0,    0.125, 1,    3.375,
        0.25, 0.5,   1,    1,
        0,    0.5,   0,    0.5,
    });
}

test "pow multiplies as often as its exponent says" {
    var seen: Seen(u64) = .{};
    const base = [_]u64{3};
    inline for (.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 31 }) |exponent| {
        try support.run(program(fromSlice(&base), .{ map(math.pow(exponent)), forEach(seenAs(u64)) }), .{&seen});
    }
    var expected: [11]u64 = undefined;
    for ([_]u64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 31 }, &expected) |exponent, *power| power.* = std.math.pow(u64, 3, exponent);
    try seen.expect(&expected);

    // Zero to the power of zero is 1, as for `std.math.pow`.
    const zero = [_]u64{0};
    try support.run(program(fromSlice(&zero), .{ map(math.pow(0)), forEach(seenAs(u64)) }), .{&seen});
    try std.testing.expectEqual(@as(u64, 1), seen.slice()[11]);
}

test "an operand may have a type, or be a float that is a whole number" {
    var seen: Seen(u32) = .{};
    const out = forEach(seenAs(u32));
    try support.run(program(range(u32, 5, 7), .{ map(math.add(@as(u8, 3))), out }), .{&seen});
    try support.run(program(range(u32, 5, 7), .{ map(math.mul(2.0)), out }), .{&seen});
    try support.run(program(range(u32, 5, 7), .{ map(math.clamp(@as(u64, 6), 9.0)), out }), .{&seen});
    try seen.expect(&.{ 8, 9, 10, 12, 6, 6 });
}

const Order = struct { cents: u32 };

test "a transform is a handler: it composes" {
    var seen: Seen(u32) = .{};
    const orders = [_]Order{ .{ .cents = 250 }, .{ .cents = 1999 } };
    const euros = compose(.{ field(.cents), math.div(100) });
    try support.run(program(fromSlice(&orders), .{ map(euros), forEach(seenAs(u32)) }), .{&seen});
    try seen.expect(&.{ 2, 19 });
}

// --- reducers -----------------------------------------------------------------

test "one reducer serves fold, scan and reduce" {
    var seen: Seen(u32) = .{};
    const out = forEach(seenAs(u32));
    try support.run(program(range(u32, 1, 5), .{ fold(0, math.sum), out }), .{&seen});
    try support.run(program(range(u32, 1, 5), .{ scan(0, math.sum), out }), .{&seen});
    try support.run(program(range(u32, 1, 6), .{ batch(2), map(reduce(0, math.sum)), out }), .{&seen});
    try seen.expect(&.{ 10, 1, 3, 6, 10, 3, 7, 5 });
}

test "a seed without a type is the reducer's: the item's type, or a usize for count" {
    var numbers: Seen(u32) = .{};
    try support.run(program(range(u32, 1, 5), .{ fold(1, math.product), forEach(seenAs(u32)) }), .{&numbers});
    try support.run(program(range(u32, 1, 5), .{ fold(std.math.maxInt(u32), math.min), forEach(seenAs(u32)) }), .{&numbers});
    try support.run(program(range(u32, 1, 5), .{ fold(0, math.max), forEach(seenAs(u32)) }), .{&numbers});
    try numbers.expect(&.{ 24, 1, 4 });

    var floats: Seen(f64) = .{};
    try support.run(program(range(u32, 1, 5), .{ map(halves), fold(0, math.sum), forEach(seenAs(f64)) }), .{&floats});
    try support.run(program(range(u32, 1, 5), .{ map(halves), fold(0.25, math.sum), forEach(seenAs(f64)) }), .{&floats});
    try support.run(program(range(u32, 1, 5), .{ map(halves), fold(std.math.inf(f64), math.min), forEach(seenAs(f64)) }), .{&floats});
    try floats.expect(&.{ 5, 5.25, 0.5 });

    // What is counted need not be a number.
    var counts: Seen(usize) = .{};
    const words = [_][]const u8{ "a", "b", "c" };
    try support.run(program(fromSlice(&words), .{ fold(0, math.count), forEach(seenAs(usize)) }), .{&counts});
    try support.run(program(fromSlice(&words), .{ scan(10, math.count), forEach(seenAs(usize)) }), .{&counts});
    try support.run(program(range(u32, 0, 5), .{ batch(3), map(reduce(0, math.count)), forEach(seenAs(usize)) }), .{&counts});
    try counts.expect(&.{ 3, 11, 12, 13, 3, 2 });
}

test "a seed with a type chooses the state" {
    var wide: Seen(u64) = .{};
    const large = [_]u32{ std.math.maxInt(u32), std.math.maxInt(u32) };
    try support.run(program(fromSlice(&large), .{ fold(@as(u64, 0), math.sum), forEach(seenAs(u64)) }), .{&wide});
    try support.run(program(fromSlice(&large), .{ fold(@as(u64, 1), math.product), forEach(seenAs(u64)) }), .{&wide});
    try support.run(program(fromSlice(&large), .{ fold(@as(u64, 1 << 40), math.min), forEach(seenAs(u64)) }), .{&wide});
    try support.run(program(fromSlice(&large), .{ fold(@as(u64, 1 << 40), math.max), forEach(seenAs(u64)) }), .{&wide});
    try wide.expect(&.{ 2 * ((1 << 32) - 1), ((1 << 32) - 1) * ((1 << 32) - 1), (1 << 32) - 1, 1 << 40 });

    // A signed state takes unsigned items that are narrower.
    var signed_total: Seen(i64) = .{};
    try support.run(program(fromSlice(&large), .{ fold(@as(i64, -1), math.sum), forEach(seenAs(i64)) }), .{&signed_total});
    try signed_total.expect(&.{2 * ((1 << 32) - 1) - 1});

    var small: Seen(u8) = .{};
    try support.run(program(range(u32, 0, 200), .{ fold(@as(u8, 0), math.count), forEach(seenAs(u8)) }), .{&small});
    try small.expect(&.{200});
}

test "the seed takes part: it is what a stream without items comes to" {
    var seen: Seen(u32) = .{};
    const out = forEach(seenAs(u32));
    // Nothing: the seed.
    try support.run(program(range(u32, 0, 0), .{ fold(7, math.sum), out }), .{&seen});
    try support.run(program(range(u32, 0, 0), .{ fold(7, math.min), out }), .{&seen});
    try support.run(program(range(u32, 0, 0), .{ fold(7, math.max), out }), .{&seen});
    // Something: the seed is reduced with the items like one of them.
    try support.run(program(range(u32, 1, 5), .{ fold(7, math.max), out }), .{&seen});
    try support.run(program(range(u32, 9, 12), .{ fold(7, math.min), out }), .{&seen});
    try seen.expect(&.{ 7, 7, 7, 7, 7 });
}

test "min and max of an optional state are null until there is an item" {
    var seen: Seen(?u32) = .{};
    const out = forEach(seenAs(?u32));
    try support.run(program(range(u32, 0, 0), .{ fold(@as(?u32, null), math.min), out }), .{&seen});
    try support.run(program(range(u32, 3, 6), .{ fold(@as(?u32, null), math.min), out }), .{&seen});
    try support.run(program(range(u32, 3, 6), .{ fold(@as(?u32, null), math.max), out }), .{&seen});
    // An optional is a value here like anywhere outside a predicate: every
    // state is emitted, the first one included.
    try support.run(program(range(u32, 3, 6), .{ scan(@as(?u32, null), math.max), out }), .{&seen});
    // A state that is not null is reduced like any seed.
    try support.run(program(range(u32, 3, 6), .{ fold(@as(?u32, 4), math.min), out }), .{&seen});
    try seen.expect(&.{ null, 3, 5, 3, 4, 5, 3 });

    var wide: Seen(?i64) = .{};
    const rows = [_][2]u32{ .{ 4, 9 }, .{ 2, 1 } };
    try support.run(program(fromSlice(&rows), .{ map(reduce(@as(?i64, null), math.max)), forEach(seenAs(?i64)) }), .{&wide});
    try wide.expect(&.{ 9, 2 });
}

// --- checked ------------------------------------------------------------------

const Bytes = Seen(u8);

test "the checked transforms return error.Overflow where the result does not fit" {
    var seen: Bytes = .{};
    const out = forEach(seenAs(u8));
    const bytes = [_]u8{ 5, 3, 100, 200, 2 };
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ map(checked.add(100)), out }), .{&seen}));
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ map(checked.sub(3)), out }), .{&seen}));
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ map(checked.mul(2)), out }), .{&seen}));
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ map(checked.pow(3)), out }), .{&seen}));
    // What fit went on, up to the item that did not.
    try seen.expect(&.{
        105, 103, 200,
        2,   0,   97,
        197, 10,  6,
        200, 125, 27,
    });
    try support.run(program(fromSlice(bytes[0..2]), .{ map(checked.add(100)), map(checked.sub(2)), map(checked.mul(2)), out }), .{&seen});
    try std.testing.expectEqualSlices(u8, &.{ 206, 202 }, seen.slice()[12..]);
}

test "checked.pow fails only where the result does not fit" {
    var seen: Seen(i8) = .{};
    const out = forEach(seenAs(i8));
    // (-2)^7 is the smallest i8: no product on the way to it is larger.
    const fits = [_]i8{ -2, 1, -1, 0 };
    try support.run(program(fromSlice(&fits), .{ map(checked.pow(7)), out }), .{&seen});
    try seen.expect(&.{ -128, 1, -1, 0 });
    const too_large = [_]i8{2};
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&too_large), .{ map(checked.pow(7)), out }), .{&seen}));
    // Any exponent of 1, 0 and -1 fits.
    try support.run(program(fromSlice(fits[1..]), .{ map(checked.pow(1000)), out }), .{&seen});
    try support.run(program(fromSlice(&too_large), .{ map(checked.pow(0)), out }), .{&seen});
    try std.testing.expectEqualSlices(i8, &.{ 1, 1, 0, 1 }, seen.slice()[4..]);
}

test "checked.neg fails for the smallest value of its type" {
    var seen: Seen(i8) = .{};
    const numbers = [_]i8{ 5, -127, 0, -128, 1 };
    const negated = program(fromSlice(&numbers), .{ map(checked.neg), forEach(seenAs(i8)) });
    try std.testing.expectError(error.Overflow, support.run(negated, .{&seen}));
    try seen.expect(&.{ -5, 127, 0 });
}

test "the checked reducers fail where the state no longer fits" {
    var seen: Bytes = .{};
    const out = forEach(seenAs(u8));
    const bytes = [_]u8{ 100, 100, 100 };
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ scan(0, checked.sum), out }), .{&seen}));
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ scan(1, checked.product), out }), .{&seen}));
    try std.testing.expectError(error.Overflow, support.run(program(fromSlice(&bytes), .{ batch(3), map(reduce(0, checked.sum)), out }), .{&seen}));
    try seen.expect(&.{ 100, 200, 100 });

    // A wider state is the way out, as for the plain forms.
    var wide: Seen(u32) = .{};
    try support.run(program(fromSlice(&bytes), .{ fold(@as(u32, 0), checked.sum), forEach(seenAs(u32)) }), .{&wide});
    try support.run(program(fromSlice(&bytes), .{ fold(@as(u32, 1), checked.product), forEach(seenAs(u32)) }), .{&wide});
    try wide.expect(&.{ 300, 1_000_000 });
}

test "error.Overflow is all a checked form can fail with" {
    var seen: Bytes = .{};
    const bytes = [_]u8{200};
    const every = program(fromSlice(&bytes), .{
        map(checked.sub(1)),
        map(checked.mul(1)),
        map(checked.pow(1)),
        map(checked.add(100)),
        fold(0, checked.sum),
        forEach(seenAs(u8)),
    });
    const left = support.runLeft(every, .{&seen});
    try std.testing.expectEqual(error.Overflow, left.err.?);
    try std.testing.expectEqualStrings("Overflow ", left.names());
}

fn largest(_: error{Overflow}, _: u8) u8 {
    return std.math.maxInt(u8);
}

const Overflowed = zrx.Failed(error{Overflow}, u8);
const Dropped = Seen(u8);
const Lost = struct { items: *Dropped };

fn lose(lost: Lost, failed: Overflowed) void {
    lost.items.add(failed.item);
}
fn zeroed(_: Overflowed) u8 {
    return 0;
}

test "an overflow is an item's error: orElse, recover and attempt take it" {
    var seen: Bytes = .{};
    const out = forEach(seenAs(u8));
    const bytes = [_]u8{ 2, 100, 3, 200 };

    // Kept, as the value the fallback makes of it.
    seen = .{};
    program(fromSlice(&bytes), .{ map(orElse(checked.mul(3), largest)), out }).run(.{&seen});
    try seen.expect(&.{ 6, 255, 9, 255 });

    // Taken out of the pipe and sent down a path, with the item as it was.
    seen = .{};
    var dropped: Dropped = .{};
    program(fromSlice(&bytes), .{
        recover(error{Overflow}, .{forEach(lose)}),
        map(checked.mul(3)),
        out,
    }).run(.{ &seen, Lost{ .items = &dropped } });
    try seen.expect(&.{ 6, 9 });
    try dropped.expect(&.{ 100, 200 });

    // Kept, as what the path makes of the failure.
    seen = .{};
    program(fromSlice(&bytes), .{
        attempt(.{ map(checked.mul(3)), map(checked.add(1)) }, error{Overflow}, .{map(zeroed)}),
        out,
    }).run(.{&seen});
    try seen.expect(&.{ 7, 0, 10, 0 });
}

// --- Stats --------------------------------------------------------------------

test "Stats keeps the count, the smallest, the largest and the mean" {
    const Summary = math.Stats(u32);
    var seen: Seen(Summary) = .{};
    const numbers = [_]u32{ 4, 1, 7, 8 };
    try support.run(program(fromSlice(&numbers), .{ fold(Summary{}, Summary.add), forEach(seenAs(Summary)) }), .{&seen});
    try support.run(program(fromSlice(&numbers), .{ scan(Summary{}, Summary.add), forEach(seenAs(Summary)) }), .{&seen});
    try support.run(program(fromSlice(&numbers), .{ batch(3), map(reduce(Summary{}, Summary.add)), forEach(seenAs(Summary)) }), .{&seen});
    try std.testing.expectEqualSlices(Summary, &.{
        .{ .count = 4, .min = 1, .max = 8, .mean = 5 },
        .{ .count = 1, .min = 4, .max = 4, .mean = 4 },
        .{ .count = 2, .min = 1, .max = 4, .mean = 2.5 },
        .{ .count = 3, .min = 1, .max = 7, .mean = 4 },
        .{ .count = 4, .min = 1, .max = 8, .mean = 5 },
        .{ .count = 3, .min = 1, .max = 7, .mean = 4 },
        .{ .count = 1, .min = 8, .max = 8, .mean = 8 },
    }, seen.slice());
}

test "Stats of nothing has a count of 0 and the values every item replaces" {
    const Whole = math.Stats(i16);
    var whole: Seen(Whole) = .{};
    try support.run(program(fromSlice(&[_]i16{}), .{ fold(Whole{}, Whole.add), forEach(seenAs(Whole)) }), .{&whole});
    try support.run(program(fromSlice(&[_]i16{ -3, -9 }), .{ fold(Whole{}, Whole.add), forEach(seenAs(Whole)) }), .{&whole});
    try std.testing.expectEqualSlices(Whole, &.{
        .{ .count = 0, .min = std.math.maxInt(i16), .max = std.math.minInt(i16), .mean = 0 },
        .{ .count = 2, .min = -9, .max = -3, .mean = -6 },
    }, whole.slice());

    const Real = math.Stats(f32);
    var real: Seen(Real) = .{};
    try support.run(program(fromSlice(&[_]f32{}), .{ fold(Real{}, Real.add), forEach(seenAs(Real)) }), .{&real});
    try support.run(program(fromSlice(&[_]f32{ 0.5, -1.5, 4 }), .{ fold(Real{}, Real.add), forEach(seenAs(Real)) }), .{&real});
    try std.testing.expectEqualSlices(Real, &.{
        .{ .count = 0, .min = std.math.inf(f32), .max = -std.math.inf(f32), .mean = 0 },
        .{ .count = 3, .min = -1.5, .max = 4, .mean = 1 },
    }, real.slice());
    // The mean of a float is a float of its type; of an integer, an f64.
    try std.testing.expect(@FieldType(Real, "mean") == f32);
    try std.testing.expect(@FieldType(Whole, "mean") == f64);
}

test "the mean of large integers does not overflow" {
    const Summary = math.Stats(u64);
    var seen: Seen(Summary) = .{};
    const large = [_]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
    try support.run(program(fromSlice(&large), .{ fold(Summary{}, Summary.add), forEach(seenAs(Summary)) }), .{&seen});
    try std.testing.expectEqual(@as(usize, 2), seen.slice()[0].count);
    try std.testing.expectEqual(@as(f64, @floatFromInt(std.math.maxInt(u64))), seen.slice()[0].mean);
}
