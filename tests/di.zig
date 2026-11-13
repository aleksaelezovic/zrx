//! Dependency injection: by type, at `run` and inside pipes.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const tap = zrx.tap;
const provide = zrx.provide;
const subscribe = zrx.subscribe;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

const Scale = struct { by: u32 };
const Offset = struct { by: u32 };

fn scale(factor: Scale, value: u32) u32 {
    return value * factor.by;
}
fn shift(offset: Offset, value: u32) u32 {
    return value + offset.by;
}
fn scaleAndShift(factor: Scale, offset: Offset, value: u32) u32 {
    return value * factor.by + offset.by;
}

test "handlers receive the dependencies they name, whatever the order at run" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scaleAndShift), subscribe(record) });
    try program(range(u32, 1, 4), work).run(.{ Offset{ .by = 1 }, &seen, Scale{ .by = 10 } });
    try seen.expect(&.{ 11, 21, 31 });
}

test "a dependency may be shared by several handlers" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scale), map(scale), subscribe(record) });
    try program(range(u32, 1, 3), work).run(.{ Scale{ .by = 3 }, &seen });
    try seen.expect(&.{ 9, 18 });
}

test "provide makes a dependency available to everything after it" {
    var seen: Numbers = .{};
    const work = pipe(.{ provide(Scale{ .by = 5 }), map(scale), subscribe(record) });
    try program(range(u32, 1, 3), work).run(.{&seen});
    try seen.expect(&.{ 5, 10 });
}

test "provide inside a nested pipe reaches the operators after that pipe" {
    var seen: Numbers = .{};
    const setup = pipe(.{ provide(Scale{ .by = 2 }), provide(Offset{ .by = 1 }) });
    try program(range(u32, 1, 3), pipe(.{ setup, map(scaleAndShift), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 3, 5 });
}

test "a later provide shadows an earlier one, from that point on" {
    var seen: Numbers = .{};
    const work = pipe(.{ map(scale), provide(Scale{ .by = 100 }), map(scale), subscribe(record) });
    try program(range(u32, 1, 3), work).run(.{ Scale{ .by = 2 }, &seen });
    try seen.expect(&.{ 200, 400 });
}

// --- generic handlers -----------------------------------------------------

fn widen(value: anytype) u64 {
    return value;
}
fn narrow(value: u64) u32 {
    return @intCast(value);
}

test "the data parameter of a handler may be generic" {
    var seen: Numbers = .{};
    try program(range(u32, 1, 3), pipe(.{ map(widen), map(narrow), subscribe(record) })).run(.{&seen});
    try seen.expect(&.{ 1, 2 });
}

const Counter = struct { total: u32 = 0 };
fn bump(counter: *Counter, value: u32) void {
    counter.total += value;
}

test "a pointer dependency is shared, not copied" {
    var counter: Counter = .{};
    try program(range(u32, 1, 4), pipe(.{ tap(bump), subscribe(bump) })).run(.{&counter});
    try std.testing.expectEqual(@as(u32, 12), counter.total);
}
