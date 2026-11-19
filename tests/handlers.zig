//! Handler combinators.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const forEach = zrx.forEach;
const not = zrx.not;
const all = zrx.all;
const any = zrx.any;
const compose = zrx.compose;
const orElse = zrx.orElse;
const require = zrx.require;
const reduce = zrx.reduce;
const field = zrx.field;
const constant = zrx.constant;
const eq = zrx.eq;
const ne = zrx.ne;
const lt = zrx.lt;
const le = zrx.le;
const gt = zrx.gt;
const ge = zrx.ge;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

const Limit = struct { max: u32 };
fn withinLimit(limit: Limit, value: u32) bool {
    return value <= limit.max;
}

const Calls = struct { count: usize = 0 };
fn counted(calls: *Calls, _: u32) bool {
    calls.count += 1;
    return true;
}

test "comparisons" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 10), pipe(.{ filter(ge(3)), filter(lt(8)), filter(ne(5)), forEach(record) })).run(.{&seen});
    try program(range(u32, 0, 10), pipe(.{ filter(any(.{ eq(0), gt(8) })), forEach(record) })).run(.{&seen});
    try program(range(u32, 0, 10), pipe(.{ filter(le(1)), forEach(record) })).run(.{&seen});
    try seen.expect(&.{ 3, 4, 6, 7, 0, 9, 0, 1 });
}

test "not, all and any forward the dependencies of their predicates" {
    var seen: Numbers = .{};
    const keep = all(.{ not(isEven), withinLimit });
    try program(range(u32, 0, 10), pipe(.{ filter(keep), forEach(record) })).run(.{ &seen, Limit{ .max = 6 } });
    try seen.expect(&.{ 1, 3, 5 });
}

test "all and any stop at the first decisive predicate" {
    var seen: Numbers = .{};
    var calls: Calls = .{};
    try program(range(u32, 0, 4), pipe(.{ filter(all(.{ isEven, counted })), forEach(record) })).run(.{ &seen, &calls });
    try std.testing.expectEqual(@as(usize, 2), calls.count);
    try program(range(u32, 0, 4), pipe(.{ filter(any(.{ isEven, counted })), forEach(record) })).run(.{ &seen, &calls });
    try std.testing.expectEqual(@as(usize, 4), calls.count);
    try seen.expect(&.{ 0, 2, 0, 1, 2, 3 });
}

fn checked(value: u32) error{Seven}!bool {
    if (value == 7) return error.Seven;
    return true;
}

test "a fallible predicate makes the combination fallible" {
    var seen: Numbers = .{};
    const result = program(range(u32, 5, 10), pipe(.{ filter(all(.{ not(checked), isEven })), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.Seven, result);
}

const Order = struct { id: u32, price: u32 };
const Tax = struct { percent: u32 };
fn addTax(tax: Tax, price: u32) u32 {
    return price + price * tax.percent / 100;
}
fn nonZero(price: u32) error{Free}!u32 {
    return if (price == 0) error.Free else price;
}

test "field projects, compose chains handlers left to right" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 250 } };
    const gross = compose(.{ field(.price), nonZero, addTax });
    try program(fromSlice(&orders), pipe(.{ map(gross), forEach(record) })).run(.{ &seen, Tax{ .percent = 20 } });
    try seen.expect(&.{ 120, 300 });

    const free = [_]Order{.{ .id = 3, .price = 0 }};
    try std.testing.expectError(error.Free, program(fromSlice(&free), pipe(.{ map(gross), forEach(record) })).run(.{ &seen, Tax{ .percent = 20 } }));
}

test "composed predicates work on projections" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 250 }, .{ .id = 3, .price = 90 } };
    const expensive = compose(.{ field(.price), ge(100) });
    try program(fromSlice(&orders), pipe(.{ filter(expensive), map(field(.id)), forEach(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2 });
}

const Fallback = struct { value: u32 };
fn positive(price: u32) error{ Free, TooHigh }!u32 {
    if (price == 0) return error.Free;
    if (price > 1000) return error.TooHigh;
    return price;
}
fn substitute(fallback: Fallback, err: error{ Free, TooHigh }, price: u32) u32 {
    return switch (err) {
        error.Free => fallback.value,
        error.TooHigh => price / 10,
    };
}
fn giveUp(err: anyerror, _: u32) error{GaveUp}!u32 {
    return if (err == error.TooHigh) error.GaveUp else 1;
}

test "orElse turns a failure into a value, with the error and the item" {
    var seen: Numbers = .{};
    const prices = [_]u32{ 5, 0, 5000 };
    try program(fromSlice(&prices), pipe(.{ map(orElse(positive, substitute)), forEach(record) })).run(.{ &seen, Fallback{ .value = 99 } });
    try seen.expect(&.{ 5, 99, 500 });
}

test "orElse works on composed handlers and may itself fail" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 0 }, .{ .id = 2, .price = 7 }, .{ .id = 3, .price = 5000 } };
    const price = orElse(compose(.{ field(.price), positive }), orderFallback);
    const result = program(fromSlice(&orders), pipe(.{ map(price), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.GaveUp, result);
    try seen.expect(&.{ 1, 7 });
}
fn orderFallback(err: anyerror, order: Order) error{GaveUp}!u32 {
    return giveUp(err, order.price);
}

var fallbacks: u32 = 0;
fn interrupted(value: u32) error{ Canceled, Odd }!u32 {
    if (value == 2) return error.Canceled;
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn countFallback(_: error{ Canceled, Odd }, _: u32) u32 {
    fallbacks += 1;
    return 0;
}

test "orElse falls back from failures but never from a cancellation" {
    var seen: Numbers = .{};
    fallbacks = 0;
    const result = program(range(u32, 0, 5), pipe(.{ map(orElse(interrupted, countFallback)), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.Canceled, result);
    try seen.expect(&.{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 1), fallbacks);
}

fn narrowFallback(_: error{Odd}, _: u32) u32 {
    fallbacks += 1;
    return 0;
}

test "a fallback need not name Canceled, which it is never given" {
    var seen: Numbers = .{};
    fallbacks = 0;
    const result = program(range(u32, 0, 5), pipe(.{ map(orElse(interrupted, narrowFallback)), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.Canceled, result);
    try seen.expect(&.{ 0, 0 });
    try std.testing.expectEqual(@as(u32, 1), fallbacks);
}

// --- require --------------------------------------------------------------

test "require passes the item on, or fails with the named error" {
    var seen: Numbers = .{};
    const values = [_]u32{ 5, 4, 2, 9 };
    const result = program(fromSlice(&values), pipe(.{ map(require(ge(3), error.TooSmall)), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.TooSmall, result);
    try seen.expect(&.{ 5, 4 });
}

test "require returns the item it was given, not what the predicate looked at" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 250 }, .{ .id = 3, .price = 9000 } };
    const affordable = require(compose(.{ field(.price), all(.{ ge(100), le(1000) }) }), error.OutOfRange);
    const result = program(fromSlice(&orders), pipe(.{ map(affordable), map(field(.id)), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.OutOfRange, result);
    try seen.expect(&.{ 1, 2 });
}

test "require forwards the predicate's dependencies" {
    var seen: Numbers = .{};
    const limited = program(range(u32, 0, 10), pipe(.{ map(require(withinLimit, error.OverLimit)), forEach(record) }));
    try std.testing.expectError(error.OverLimit, limited.run(.{ &seen, Limit{ .max = 2 } }));
    try seen.expect(&.{ 0, 1, 2 });
}

test "require fails with the predicate's own error when the predicate fails" {
    const Checked = zrx.di.Result("test", require(checked, error.Rejected), &.{u32});
    try std.testing.expect(Checked == error{ Rejected, Seven }!u32);
    try std.testing.expect(zrx.di.Result("test", require(isEven, error.Odd), &.{u32}) == error{Odd}!u32);

    var seen: Numbers = .{};
    const result = program(range(u32, 5, 10), pipe(.{ map(require(checked, error.Rejected)), forEach(record) })).run(.{&seen});
    try std.testing.expectError(error.Seven, result);
    try seen.expect(&.{ 5, 6 });
}

fn priceOrZero(_: error{ Free, Cheap }, _: Order) u32 {
    return 0;
}

test "require works inside compose and under orElse" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 0 }, .{ .id = 3, .price = 50 }, .{ .id = 4, .price = 300 } };
    const gross = compose(.{ field(.price), nonZero, require(ge(100), error.Cheap), addTax });
    try program(fromSlice(&orders), pipe(.{ map(orElse(gross, priceOrZero)), forEach(record) })).run(.{ &seen, Tax{ .percent = 10 } });
    try seen.expect(&.{ 110, 0, 0, 330 });
}

const Rejected = struct { odd: u32 = 0 };
fn countOdd(rejected: *Rejected, _: zrx.Failed(error{Odd}, u32)) void {
    rejected.odd += 1;
}

test "an item that require fails can be skipped with recover" {
    var seen: Numbers = .{};
    var rejected: Rejected = .{};
    const evens = pipe(.{ zrx.recover(error{Odd}, .{forEach(countOdd)}), map(require(isEven, error.Odd)), forEach(record) });
    try program(range(u32, 0, 5), evens).run(.{ &seen, &rejected });
    try seen.expect(&.{ 0, 2, 4 });
    try std.testing.expectEqual(@as(u32, 2), rejected.odd);
}

test "constant replaces every item" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 3), pipe(.{ map(constant(@as(u32, 9))), forEach(record) })).run(.{&seen});
    try seen.expect(&.{ 9, 9, 9 });
}

// --- reduce ---------------------------------------------------------------

fn sum(total: u32, value: u32) u32 {
    return total + value;
}

const Scale = struct { by: u32 };
fn scaledSum(scale: Scale, total: u32, value: u32) u32 {
    return total + value * scale.by;
}

fn sumBelowTen(total: u32, value: u32) error{TooLarge}!u32 {
    if (value >= 10) return error.TooLarge;
    return total + value;
}

test "reduce folds the elements of an array, slice or batch item" {
    var seen: Numbers = .{};
    const rows = [_][3]u32{ .{ 1, 2, 3 }, .{ 10, 20, 30 } };
    try program(fromSlice(&rows), .{ map(reduce(0, sum)), forEach(record) }).run(.{&seen});

    const slices = [_][]const u32{ &.{ 4, 5 }, &.{}, &.{6} };
    try program(fromSlice(&slices), .{ map(reduce(100, sum)), forEach(record) }).run(.{&seen});

    // The last batch is partial: only its valid items are folded.
    try program(range(u32, 1, 6), .{ zrx.batch(2), map(reduce(0, sum)), forEach(record) }).run(.{&seen});
    try seen.expect(&.{ 6, 60, 109, 100, 106, 3, 7, 5 });
}

test "reduce forwards the reducer's dependencies and its errors" {
    var seen: Numbers = .{};
    const rows = [_][2]u32{ .{ 1, 2 }, .{ 3, 4 } };
    try program(fromSlice(&rows), .{ map(reduce(0, scaledSum)), forEach(record) }).run(.{ &seen, Scale{ .by = 10 } });
    try seen.expect(&.{ 30, 70 });

    const mixed = [_][2]u32{ .{ 1, 2 }, .{ 3, 40 } };
    const failing = program(fromSlice(&mixed), .{ map(reduce(0, sumBelowTen)), forEach(record) });
    try std.testing.expectError(error.TooLarge, failing.run(.{&seen}));
    try seen.expect(&.{ 30, 70, 3 });
}

const Spread = struct {
    low: u32 = std.math.maxInt(u32),
    high: u32 = 0,

    fn add(spread: Spread, value: u32) Spread {
        return .{ .low = @min(spread.low, value), .high = @max(spread.high, value) };
    }

    fn width(spread: Spread) u32 {
        return spread.high - spread.low;
    }
};

test "reduce composes: a struct seed, then a handler over the result" {
    var seen: Numbers = .{};
    const rows = [_][3]u32{ .{ 5, 1, 9 }, .{ 7, 7, 7 } };
    try program(fromSlice(&rows), .{ map(compose(.{ reduce(Spread{}, Spread.add), Spread.width })), forEach(record) }).run(.{&seen});
    try seen.expect(&.{ 8, 0 });
}
