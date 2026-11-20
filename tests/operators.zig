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
const Failed = zrx.Failed;
const forEach = zrx.forEach;
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

test "map, filter and forEach run in order" {
    var seen: Numbers = .{};
    const values = [_]u32{ 1, 2, 3, 4, 5 };
    try support.run(program(fromSlice(&values), pipe(.{ filter(isEven), map(double), forEach(record) })), .{&seen});
    try seen.expect(&.{ 4, 8 });
}

test "a nested pipe is the same as its operators written inline" {
    var nested: Numbers = .{};
    var flat: Numbers = .{};
    const values = [_]u32{ 1, 2, 3, 4 };
    const evens = pipe(.{ filter(isEven), map(double) });
    try support.run(program(fromSlice(&values), pipe(.{ map(double), pipe(.{ evens, pipe(.{forEach(record)}) }) })), .{&nested});
    try support.run(program(fromSlice(&values), pipe(.{ map(double), filter(isEven), map(double), forEach(record) })), .{&flat});
    try nested.expect(flat.slice());
    try nested.expect(&.{ 4, 8, 12, 16 });
}

test "a pipe is a value that can be reused" {
    var first: Numbers = .{};
    var second: Numbers = .{};
    const doubled = pipe(.{ map(double), forEach(record) });
    try support.run(program(range(u32, 0, 3), doubled), .{&first});
    try support.run(program(range(u32, 10, 12), doubled), .{&second});
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
    try support.run(program(range(u32, 1, 4), pipe(.{ tap(audit), map(double), forEach(record) })), .{ &seen, Audit{ .seen = &tapped } });
    try tapped.expect(&.{ 1, 2, 3 });
    try seen.expect(&.{ 2, 4, 6 });
}

test "scan emits every running state" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 1, 5), pipe(.{ scan(@as(u32, 0), add), forEach(record) })), .{&seen});
    try seen.expect(&.{ 1, 3, 6, 10 });
}

test "fold emits the final state once, and the seed for an empty stream" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 1, 5), pipe(.{ fold(@as(u32, 0), add), forEach(record) })), .{&seen});
    try support.run(program(range(u32, 0, 0), pipe(.{ fold(@as(u32, 7), add), forEach(record) })), .{&seen});
    try seen.expect(&.{ 10, 7 });
}

test "the seed takes the reducer's state type" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 1, 4), pipe(.{ fold(0, add), forEach(record) })), .{&seen});
    try seen.expect(&.{6});
}

const Pulls = struct { count: usize = 0 };
fn countPull(pulls: *Pulls, _: u32) void {
    pulls.count += 1;
}

test "take stops the source as soon as it has enough" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    try support.run(program(range(u32, 0, 1_000_000), pipe(.{ tap(countPull), take(3), forEach(record) })), .{ &seen, &pulls });
    try seen.expect(&.{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), pulls.count);
}

test "take(0) reads nothing but still finishes the pipe" {
    var seen: Numbers = .{};
    var pulls: Pulls = .{};
    try support.run(program(range(u32, 0, 10), pipe(.{ tap(countPull), take(0), fold(@as(u32, 5), add), forEach(record) })), .{ &seen, &pulls });
    try seen.expect(&.{5});
    try std.testing.expectEqual(@as(usize, 1), pulls.count);
}

test "a fold above a finished take still delivers nothing past it" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 1, 4), pipe(.{ take(2), fold(@as(u32, 0), add), take(0), forEach(record) })), .{&seen});
    try seen.expect(&.{});
}

test "skip and takeWhile" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 100), pipe(.{ skip(7), takeWhile(below10), forEach(record) })), .{&seen});
    try seen.expect(&.{ 7, 8, 9 });
}

fn pair(value: u32) [2]u32 {
    return .{ value, value + 100 };
}

test "flatten emits each element and stops mid-item when asked" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 10), pipe(.{ map(pair), flatten(), take(3), forEach(record) })), .{&seen});
    try seen.expect(&.{ 0, 100, 1 });
}

test "flatten accepts slices" {
    var seen: Numbers = .{};
    const rows = [_][]const u32{ &.{ 1, 2 }, &.{}, &.{3} };
    try support.run(program(fromSlice(&rows), pipe(.{ flatten(), forEach(record) })), .{&seen});
    try seen.expect(&.{ 1, 2, 3 });
}

fn sumOf(values: zrx.Batch(u32, 3)) u32 {
    var total: u32 = 0;
    for (values.slice()) |value| total += value;
    return total;
}
fn count(values: zrx.Batch(u32, 3)) u32 {
    return @intCast(values.len);
}

test "batch groups items and flushes the remainder at the end" {
    var sums: Numbers = .{};
    var sizes: Numbers = .{};
    try support.run(program(range(u32, 1, 8), pipe(.{ batch(3), map(sumOf), forEach(record) })), .{&sums});
    try support.run(program(range(u32, 1, 8), pipe(.{ batch(3), map(count), forEach(record) })), .{&sizes});
    try sums.expect(&.{ 6, 15, 7 });
    try sizes.expect(&.{ 3, 3, 1 });
}

test "drain ends a pipe" {
    var tapped: Numbers = .{};
    try support.run(program(range(u32, 0, 3), pipe(.{ tap(audit), drain() })), .{Audit{ .seen = &tapped }});
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
    const result = support.run(program(range(u32, 0, 10), pipe(.{ map(evenOnly), forEach(record) })), .{&seen});
    try std.testing.expectError(error.Odd, result);
    try seen.expect(&.{0});
}

const Rejected = struct { seen: *Numbers };
fn reject(log: Rejected, failed: anytype) void {
    log.seen.add(failed.item);
}
const rejections = pipe(.{forEach(reject)});

test "recover sends the items its guarded operators fail on down its path" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    try support.run(program(range(u32, 0, 6), pipe(.{ recover(anyerror, rejections), map(evenOnly), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try seen.expect(&.{ 0, 2, 4 });
    try rejected.expect(&.{ 1, 3, 5 });
}

fn rejectOdd(log: Rejected, failed: Failed(error{Odd}, u32)) void {
    std.debug.assert(failed.err == error.Odd);
    log.seen.add(failed.item);
}

test "recover with an error set lets other errors through" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const values = [_]u32{ 2, 3, 4, 500, 6 };
    const result = support.run(program(fromSlice(&values), pipe(.{ recover(error{Odd}, .{forEach(rejectOdd)}), map(evenOnly), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try std.testing.expectError(error.TooBig, result);
    try seen.expect(&.{ 2, 4 });
    try rejected.expect(&.{3});
}

test "what an error path takes is no longer among the errors of the run" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const deps = .{ &seen, Rejected{ .seen = &rejected } };
    const values = [_]u32{ 2, 3, 500 };
    // `Odd` is taken; `TooBig` is what is left, and the run fails with it.
    const some = program(fromSlice(&values), pipe(.{ recover(error{Odd}, .{forEach(rejectOdd)}), map(evenOnly), forEach(record) }));
    const left = support.runLeft(some, deps);
    try std.testing.expectEqualStrings("TooBig ", left.names());
    try std.testing.expectEqual(error.TooBig, left.err.?);

    // Nothing is left: this compiles without a rescue.
    program(fromSlice(&values), pipe(.{ recover(anyerror, rejections), map(evenOnly), forEach(record) })).run(deps);
    try seen.expect(&.{ 2, 2 });
    try rejected.expect(&.{ 3, 3, 500 });
}

fn escalate(failed: Failed(anyerror, u32)) error{Fatal}!void {
    if (failed.item == 3) return error.Fatal;
}

test "an error path can fail the run itself" {
    var seen: Numbers = .{};
    const result = support.run(program(range(u32, 0, 6), pipe(.{ recover(anyerror, .{forEach(escalate)}), map(evenOnly), forEach(record) })), .{&seen});
    try std.testing.expectError(error.Fatal, result);
    try seen.expect(&.{ 0, 2 });
}

fn failedItem(failed: Failed(anyerror, u32)) u32 {
    return failed.item;
}
fn countOne(so_far: u32, _: u32) u32 {
    return so_far + 1;
}
fn noteCount(log: Rejected, total: u32) void {
    log.seen.add(total);
}

test "an error path has stages, state and an end of the stream of its own" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const counted = pipe(.{ map(failedItem), filter(below10), fold(@as(u32, 0), countOne), forEach(noteCount) });
    const values = [_]u32{ 2, 3, 4, 500, 7, 6 };
    try support.run(program(fromSlice(&values), pipe(.{ recover(anyerror, counted), map(evenOnly), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try seen.expect(&.{ 2, 4, 6 });
    // One value, at the end: the failures below ten.
    try rejected.expect(&.{2});
}

test "an error path that wants no more ends the stream" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const first = pipe(.{ take(1), forEach(reject) });
    // The stream ends as it ends anywhere: the run succeeds, and the fold
    // after the recover still emits what it had.
    try support.run(program(range(u32, 0, 10), pipe(.{ recover(anyerror, first), map(evenOnly), filter(isPositive), fold(@as(u32, 0), add), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try rejected.expect(&.{1});
    try seen.expect(&.{0});

    seen = .{};
    rejected = .{};
    const two = pipe(.{ take(2), forEach(reject) });
    try support.run(program(range(u32, 0, 10), pipe(.{ recover(anyerror, two), map(evenOnly), fold(@as(u32, 0), add), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try rejected.expect(&.{ 1, 3 });
    try seen.expect(&.{2});
}

fn isPositive(value: u32) bool {
    return value > 0;
}

fn interrupted(value: u32) error{ Canceled, Odd }!u32 {
    if (value == 2) return error.Canceled;
    if (value % 2 == 1) return error.Odd;
    return value;
}

test "a cancellation is never handed to an error path" {
    inline for (.{ anyerror, error{ Canceled, Odd } }) |Taken| {
        var seen: Numbers = .{};
        var rejected: Numbers = .{};
        const result = support.run(program(range(u32, 0, 6), pipe(.{ recover(Taken, rejections), map(interrupted), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
        try std.testing.expectError(error.Canceled, result);
        try seen.expect(&.{0});
        try rejected.expect(&.{1});
    }
}

/// Fails with anything: nothing is known about its errors where it is guarded.
fn loose(value: u32) anyerror!u32 {
    return switch (value) {
        1 => error.Odd,
        3 => error.TooBig,
        5 => error.Canceled,
        else => value,
    };
}

test "recover selects what it takes also where any error is possible" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const some = program(range(u32, 0, 8), pipe(.{ recover(error{Odd}, rejections), map(loose), forEach(record) }));
    try std.testing.expectError(error.TooBig, support.run(some, .{ &seen, Rejected{ .seen = &rejected } }));
    try seen.expect(&.{ 0, 2 });
    try rejected.expect(&.{1});

    seen = .{};
    rejected = .{};
    const every = program(range(u32, 0, 8), pipe(.{ recover(anyerror, rejections), map(loose), forEach(record) }));
    try std.testing.expectError(error.Canceled, support.run(every, .{ &seen, Rejected{ .seen = &rejected } }));
    try seen.expect(&.{ 0, 2, 4 });
    try rejected.expect(&.{ 1, 3 });
}

test "recover only guards what comes after it" {
    var seen: Numbers = .{};
    var rejected: Numbers = .{};
    const result = support.run(program(range(u32, 0, 6), pipe(.{ map(evenOnly), recover(anyerror, rejections), forEach(record) })), .{ &seen, Rejected{ .seen = &rejected } });
    try std.testing.expectError(error.Odd, result);
    try rejected.expect(&.{});
}

fn failOnFinish(_: u32) error{Late}!void {
    return error.Late;
}

test "a final value from before a recover is an item like any other" {
    var rejected: Numbers = .{};
    // The fold stands before the recover: what it emits when the stream ends
    // passes through the recover, which guards what fails for it.
    try support.run(program(range(u32, 0, 4), pipe(.{ fold(@as(u32, 0), add), recover(anyerror, rejections), forEach(failOnFinish) })), .{Rejected{ .seen = &rejected }});
    try rejected.expect(&.{6});
}

test "an error of a later stage's own end of stream is not an item error" {
    var rejected: Numbers = .{};
    const result = support.run(program(range(u32, 0, 3), pipe(.{ recover(anyerror, rejections), fold(@as(u32, 0), add), forEach(failOnFinish) })), .{Rejected{ .seen = &rejected }});
    try std.testing.expectError(error.Late, result);
    try rejected.expect(&.{});
}
