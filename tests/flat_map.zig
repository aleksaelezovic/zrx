const std = @import("std");
const zrx = @import("zrx");
const flatMap = zrx.flatMap;
const pipe = zrx.pipe;
const fromValue = zrx.fromValue;
const fromSlice = zrx.fromSlice;
const fromService = zrx.fromService;
const map = zrx.map;
const forEach = zrx.forEach;
const recover = zrx.recover;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;
const One = @TypeOf(fromValue(@as(u32, 0)));
const Many = @TypeOf(fromSlice(@as([]const u32, undefined)));

const Result = struct { items: std.ArrayList(u32) = .empty, factories: usize = 0 };
fn save(result: *Result, value: u32) !void {
    try result.items.append(allocator, value);
}
fn expand(result: *Result, values: []const u32) Many {
    result.factories += 1;
    return fromSlice(values);
}

test "flatMap constructs nothing cold, skips empty children and drains in order" {
    const inputs = [_][]const u32{ &.{ 1, 2 }, &.{}, &.{ 3, 4 } };
    var result: Result = .{};
    defer result.items.deinit(allocator);
    const flow = pipe(fromSlice(&inputs), .{ flatMap(expand), forEach(save) });
    try std.testing.expectEqual(@as(usize, 0), result.factories);
    try run(.{ allocator, io, &result }, .{flow});
    try std.testing.expectEqual(@as(usize, 3), result.factories);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, result.items.items);
    result.factories = 0;
    const empty: []const []const u32 = &.{};
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(empty), .{ flatMap(expand), forEach(save) }),
    });
    try std.testing.expectEqual(@as(usize, 0), result.factories);
}

fn addValues(previous: u32, value: u32) u32 {
    return previous + value;
}
const Folded = @TypeOf(pipe(fromSlice(@as([]const u32, undefined)), .{zrx.fold(@as(u32, 0), addValues)}));
fn foldChild(result: *Result, values: []const u32) Folded {
    result.factories += 1;
    return pipe(fromSlice(values), .{zrx.fold(@as(u32, 0), addValues)});
}

test "a selected empty child folds its seed but absent outer items emit nothing" {
    var result: Result = .{};
    defer result.items.deinit(allocator);
    const inputs = [_][]const u32{ &.{}, &.{ 1, 2 }, &.{}, &.{4} };
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(&inputs), .{ flatMap(foldChild), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 0, 4 }, result.items.items);
    try std.testing.expectEqual(@as(usize, 4), result.factories);
    result.items.clearRetainingCapacity();
    result.factories = 0;
    const empty: []const []const u32 = &.{};
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(empty), .{ flatMap(foldChild), forEach(save) }),
    });
    try std.testing.expectEqual(@as(usize, 0), result.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.factories);
}

fn failingFactory(result: *Result, value: u32) error{BadFactory}!One {
    result.factories += 1;
    if (value == 0) return error.BadFactory;
    return fromValue(value);
}
fn operation(value: u32) error{BadChild}!u32 {
    return if (value == 1) error.BadChild else value;
}
fn childOperations(value: u32) @TypeOf(pipe(fromValue(@as(u32, 0)), .{map(operation)})) {
    return pipe(fromValue(value), .{map(operation)});
}
fn replace(_: anyerror) u32 {
    return 99;
}

test "factory and child operation failures remain pending and recover downstream" {
    var result: Result = .{};
    defer result.items.deinit(allocator);
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(&[_]u32{ 0, 1, 2 }), .{ flatMap(failingFactory), recover(replace), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 99, 1, 2 }, result.items.items);
    result.items.clearRetainingCapacity();
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(&[_]u32{ 0, 1, 2 }), .{ flatMap(childOperations), recover(replace), forEach(save) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 0, 99, 2 }, result.items.items);
}

fn outerFailure(value: u32) error{BadOuter}!u32 {
    return if (value == 0) error.BadOuter else value;
}

test "pending outer failures bypass the factory and take stops without another child" {
    var result: Result = .{};
    defer result.items.deinit(allocator);
    try run(.{ allocator, io, &result }, .{
        pipe(fromSlice(&[_]u32{ 0, 1, 2 }), .{
            map(outerFailure), flatMap(failingFactory), recover(replace), zrx.take(2), forEach(save),
        }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 99, 1 }, result.items.items);
    try std.testing.expectEqual(@as(usize, 1), result.factories);
}

const Nested = struct { value: u32 };
const Life = struct { acquired: usize = 0, released: usize = 0 };
fn acquire(life: *Life, _: void) Nested {
    life.acquired += 1;
    return .{ .value = 17 };
}
fn release(life: *Life, _: Nested) void {
    life.released += 1;
}
fn nested(_: u32) @TypeOf(pipe(fromService(Nested), .{map(unwrap)})) {
    return pipe(fromService(Nested), .{map(unwrap)});
}
fn unwrap(value: Nested) u32 {
    return value.value;
}

test "child requirements join the run plan and new runs get fresh cursors" {
    var life: Life = .{};
    var result: Result = .{};
    defer result.items.deinit(allocator);
    const flow = pipe(fromSlice(&[_]u32{ 1, 2 }), .{ flatMap(nested), forEach(save) });
    for (0..2) |_| {
        try run(.{ allocator, io, &life, &result, zrx.resource({}, acquire, release) }, .{flow});
    }
    try std.testing.expectEqualSlices(u32, &.{ 17, 17, 17, 17 }, result.items.items);
    try std.testing.expectEqual(@as(usize, 2), life.acquired);
    try std.testing.expectEqual(life.acquired, life.released);
}

const Broken = struct {
    pub fn next(_: *Broken) error{SourceFailed}!?u32 {
        return error.SourceFailed;
    }
};
fn broken(input: *Broken, _: u32) @TypeOf(zrx.fromIterator(@as(*Broken, undefined))) {
    return zrx.fromIterator(input);
}
fn canceled(_: u32) error{Canceled}!@TypeOf(fromValue(@as(u32, 1))) {
    return error.Canceled;
}
fn forbidden(_: anyerror) u32 {
    @panic("control error reached recovery");
}

test "child iterator failures and cancellation remain execution control" {
    var input: Broken = .{};
    try std.testing.expectError(error.SourceFailed, run(.{ allocator, io, &input }, .{
        pipe(fromValue(@as(u32, 1)), .{ flatMap(broken), recover(forbidden), zrx.discard() }),
    }));
    try std.testing.expectError(error.Canceled, run(.{ allocator, io }, .{
        pipe(fromValue(@as(u32, 1)), .{ flatMap(canceled), recover(forbidden), zrx.discard() }),
    }));
}

fn shared(result: *Result, value: u32) One {
    result.factories += 1;
    return fromValue(value);
}
fn sum(total: *u32, value: u32) void {
    total.* += value;
}
fn ignore(_: u32) void {}

test "an explicitly shared expanded stage evaluates once" {
    var result: Result = .{};
    var total: u32 = 0;
    const source = pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{flatMap(shared)});
    try run(.{ allocator, io, &result, &total }, .{
        pipe(&source, .{forEach(sum)}),
        pipe(&source, .{forEach(ignore)}),
    });
    try std.testing.expectEqual(@as(u32, 6), total);
    try std.testing.expectEqual(@as(usize, 3), result.factories);
}
