//! Per-item operators, composition and early stop.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const scan = zrx.scan;
const fold = zrx.fold;
const take = zrx.take;
const skip = zrx.skip;
const takeWhile = zrx.takeWhile;
const flatten = zrx.flatten;
const batch = zrx.batch;
const recover = zrx.recover;
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
fn below10(value: u32) bool {
    return value < 10;
}

test "map, filter and subscribe run in order" {
    var seen: Numbers = .{};
    const values = [_]u32{ 1, 2, 3, 4, 5 };
    try program(fromSlice(&values), pipe(.{ filter(isEven), map(double), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 4, 8 });
}

test "a nested pipe is the same as its operators written inline" {
    var nested: Numbers = .{};
    var flat: Numbers = .{};
    const values = [_]u32{ 1, 2, 3, 4 };
    const evens = pipe(.{ filter(isEven), map(double) });
    try program(fromSlice(&values), pipe(.{ map(double), pipe(.{ evens, pipe(.{subscribe(record)}) }) })).run(.{&nested});
    try program(fromSlice(&values), pipe(.{ map(double), filter(isEven), map(double), subscribe(record) })).run(.{&flat});
    try nested.expect(flat.slice());
    try nested.expect(&.{ 4, 8, 12, 16 });
}

test "a pipe is a value that can be reused" {
    var first: Numbers = .{};
    var second: Numbers = .{};
    const doubled = pipe(.{ map(double), subscribe(record) });
    try program(range(u32, 0, 3), doubled).run(.{&first});
    try program(range(u32, 10, 12), doubled).run(.{&second});
    try first.expect(&.{ 0, 2, 4 });
    try second.expect(&.{ 20, 22 });
}

const Audit = struct { seen: *Numbers };
fn audit(log: Audit, value: u32) void {
    log.seen.add(value);
}

test "tap observes items without changing them" {
    var tapped: Numbers = .{};
    var seen: Numbers = .{};
    try program(range(u32, 1, 4), pipe(.{ tap(audit), map(double), subscribe(record) })).run(.{ &seen, Audit{ .seen = &tapped } });
    try tapped.expect(&.{ 1, 2, 3 });
    try seen.expect(&.{ 2, 4, 6 });
}

test "scan emits every running state" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 5), pipe(.{ scan(@as(u32, 0), add), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 3, 6, 10 });
}

test "fold emits the final state once, and the seed for an empty stream" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 5), pipe(.{ fold(@as(u32, 0), add), subscribe(record) })).run(.{&seen});
    try program(range(u32, 0, 0), pipe(.{ fold(@as(u32, 7), add), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 10, 7 });
}

test "the seed takes the reducer's state type" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 4), pipe(.{ fold(0, add), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{6});
}

const Pulls = struct { count: usize = 0 };
fn countPull(pulls: *Pulls, _: u32) void {
    pulls.count += 1;
}

test "take stops the source as soon as it has enough" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    try program(range(u32, 0, 1_000_000), pipe(.{ tap(countPull), take(3), subscribe(record) })).run(.{ &seen, &pulls });
    try seen.expect(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), pulls.count);
}

test "take(0) reads nothing but still finishes the pipe" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    try program(range(u32, 0, 10), pipe(.{ tap(countPull), take(0), fold(@as(u32, 5), add), subscribe(record) })).run(.{ &seen, &pulls });
    try seen.expect(&.{5});
    try std.testing.expectEqual(@as(usize, 1), pulls.count);
}

test "a fold above a finished take still delivers nothing past it" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 4), pipe(.{ take(2), fold(@as(u32, 0), add), take(0), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{});
}

test "skip and takeWhile" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 100), pipe(.{ skip(7), takeWhile(below10), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 7, 8, 9 });
}

fn pair(value: u32) [2]u32 {
    return .{ value, value + 100 };
}

test "flatten emits each element and stops mid-item when asked" {
    var seen: Numbers = .{};
    try program(range(u32, 0, 10), pipe(.{ map(pair), flatten(), take(3), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 0, 100, 1 });
}

test "flatten accepts slices" {
    var seen: Numbers = .{};
    const rows = [_][]const u32{ &.{ 1, 2 }, &.{}, &.{3} };
    try program(fromSlice(&rows), pipe(.{ flatten(), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2, 3 });
}

fn sumOf(values: []const u32) u32 {
    var total: u32 = 0;
    for (values) |value| total += value;
    return total;
}
fn count(values: []const u32) u32 {
    return @intCast(values.len);
}

test "batch groups items and flushes the remainder at the end" {
    var sums: Numbers = .{};
    var sizes: Numbers = .{};
    try program(range(u32, 1, 8), pipe(.{ batch(3), map(sumOf), subscribe(record) })).run(.{&sums});
    try program(range(u32, 1, 8), pipe(.{ batch(3), map(count), subscribe(record) })).run(.{&sizes});
    try sums.expect(&.{ 6, 15, 7 });
    try sizes.expect(&.{ 3, 3, 1 });
}

test "drain ends a pipe" {
    var tapped: Numbers = .{};
    try program(range(u32, 0, 3), pipe(.{ tap(audit), drain() })).run(.{Audit{ .seen = &tapped }});
    try tapped.expect(&.{ 0, 1, 2 });
}

// --- errors ---------------------------------------------------------------

const ParseError = error{ Odd, TooBig };
fn evenOnly(value: u32) ParseError!u32 {
    if (value > 100) return error.TooBig;
    if (value % 2 == 1) return error.Odd;
    return value;
}

test "a handler error fails the run and stops the stream" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 10), pipe(.{ map(evenOnly), subscribe(record) })).run(.{&seen});
    try std.testing.expectError(error.Odd, result);
    try seen.expect(&.{0});
}

const Rejected = struct { seen: *Numbers };
fn reject(log: Rejected, _: anyerror, value: u32) void {
    log.seen.add(value);
}

test "recover skips the items its guarded operators fail on" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    try program(range(u32, 0, 6), pipe(.{ recover(reject), map(evenOnly), subscribe(record) })).run(.{ &seen, Rejected{ .seen = &rejected } });
    try seen.expect(&.{ 0, 2, 4 });
    try rejected.expect(&.{ 1, 3, 5 });
}

fn rejectOdd(log: Rejected, err: error{Odd}, value: u32) void {
    std.debug.assert(err == error.Odd);
    log.seen.add(value);
}

test "recover with an error set lets other errors through" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const values = [_]u32{ 2, 3, 4, 500, 6 };
    const result = program(fromSlice(&values), pipe(.{ recover(rejectOdd), map(evenOnly), subscribe(record) })).run(.{ &seen, Rejected{ .seen = &rejected } });
    try std.testing.expectError(error.TooBig, result);
    try seen.expect(&.{ 2, 4 });
    try rejected.expect(&.{3});
}

fn escalate(_: anyerror, value: u32) error{Fatal}!void {
    if (value == 3) return error.Fatal;
}

test "a recover handler can fail the run itself" {
    var seen: Numbers = .{};
    const result = program(range(u32, 0, 6), pipe(.{ recover(escalate), map(evenOnly), subscribe(record) })).run(.{&seen});
    try std.testing.expectError(error.Fatal, result);
    try seen.expect(&.{ 0, 2 });
}

test "recover only guards what comes after it" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const result = program(range(u32, 0, 6), pipe(.{ map(evenOnly), recover(reject), subscribe(record) })).run(.{ &seen, Rejected{ .seen = &rejected } });
    try std.testing.expectError(error.Odd, result);
    try rejected.expect(&.{});
}

fn failOnFinish(_: u32) error{Late}!void {
    return error.Late;
}

test "a final value is an item too: a recover after the fold guards it" {
    var rejected: Numbers = .{};
    try program(range(u32, 0, 3), pipe(.{ fold(@as(u32, 0), add), recover(reject), subscribe(failOnFinish) })).run(.{Rejected{ .seen = &rejected }});
    try rejected.expect(&.{3});
}

test "the last, partial batch is guarded like every other batch" {
    var rejected: Numbers = .{};
    var seen: Numbers = .{};
    const work = pipe(.{ batch(2), map(count), recover(reject), map(evenOnly), subscribe(record) });
    try program(range(u32, 0, 5), work).run(.{ &seen, Rejected{ .seen = &rejected } });
    try seen.expect(&.{ 2, 2 });
    try rejected.expect(&.{1});
}

test "a recover before the fold does not see the fold's final value" {
    var rejected: Numbers = .{};
    const result = program(range(u32, 0, 3), pipe(.{ recover(reject), fold(@as(u32, 0), add), subscribe(failOnFinish) })).run(.{Rejected{ .seen = &rejected }});
    try std.testing.expectError(error.Late, result);
    try rejected.expect(&.{});
}
