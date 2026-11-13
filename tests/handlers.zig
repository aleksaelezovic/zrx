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
const subscribe = zrx.subscribe;
const not = zrx.not;
const all = zrx.all;
const any = zrx.any;
const compose = zrx.compose;
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
    try program(range(u32, 0, 10), pipe(.{ filter(ge(3)), filter(lt(8)), filter(ne(5)), subscribe(record) })).run(.{&seen});
    try program(range(u32, 0, 10), pipe(.{ filter(any(.{ eq(0), gt(8) })), subscribe(record) })).run(.{&seen});
    try program(range(u32, 0, 10), pipe(.{ filter(le(1)), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 3, 4, 6, 7, 0, 9, 0, 1 });
}

test "not, all and any forward the dependencies of their predicates" {
    var seen: Numbers = .{};
    const keep = all(.{ not(isEven), withinLimit });
    try program(range(u32, 0, 10), pipe(.{ filter(keep), subscribe(record) })).run(.{ &seen, Limit{ .max = 6 } });
    try seen.expect(&.{ 1, 3, 5 });
}

test "all and any stop at the first decisive predicate" {
    var seen: Numbers = .{};
    var calls: Calls = .{};
    try program(range(u32, 0, 4), pipe(.{ filter(all(.{ isEven, counted })), subscribe(record) })).run(.{ &seen, &calls });
    try std.testing.expectEqual(@as(usize, 2), calls.count);
    try program(range(u32, 0, 4), pipe(.{ filter(any(.{ isEven, counted })), subscribe(record) })).run(.{ &seen, &calls });
    try std.testing.expectEqual(@as(usize, 4), calls.count);
    try seen.expect(&.{ 0, 2, 0, 1, 2, 3 });
}

fn checked(value: u32) error{Seven}!bool {
    if (value == 7) return error.Seven;
    return true;
}

test "a fallible predicate makes the combination fallible" {
    var seen: Numbers = .{};
    const result = program(range(u32, 5, 10), pipe(.{ filter(all(.{ not(checked), isEven })), subscribe(record) })).run(.{&seen});
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
    try program(fromSlice(&orders), pipe(.{ map(gross), subscribe(record) })).run(.{ &seen, Tax{ .percent = 20 } });
    try seen.expect(&.{ 120, 300 });

    const free = [_]Order{.{ .id = 3, .price = 0 }};
    try std.testing.expectError(error.Free, program(fromSlice(&free), pipe(.{ map(gross), subscribe(record) })).run(.{ &seen, Tax{ .percent = 20 } }));
}

test "composed predicates work on projections" {
    var seen: Numbers = .{};
    const orders = [_]Order{ .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 250 }, .{ .id = 3, .price = 90 } };
    const expensive = compose(.{ field(.price), ge(100) });
    try program(fromSlice(&orders), pipe(.{ filter(expensive), map(field(.id)), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2 });
}

test "constant replaces every item" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 3), pipe(.{ map(constant(@as(u32, 9))), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 9, 9, 9 });
}
