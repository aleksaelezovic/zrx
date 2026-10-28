const std = @import("std");
const zrx = @import("zrx");
const catalog = @import("catalog.zig");
const pipe = zrx.pipe;
const map = zrx.map;
const keepIf = zrx.keepIf;
const each = zrx.each;

fn double(value: u32) u32 {
    return value *% 2;
}

fn increment(value: u32) u32 {
    return value +% 1;
}

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

fn score(value: bool) u32 {
    return if (value) 10 else 20;
}

// Exported parameters force real runtime-input implementations to be generated,
// rather than testing only constant-folded calls or uninstantiated generics.
export fn arithmetic_direct(value: u32) u32 {
    const doubled = double(value);
    return increment(doubled);
}

export fn arithmetic_grouped(value: u32) u32 {
    return pipe(value, .{map(.{ double, increment })});
}

export fn arithmetic_separate(value: u32) u32 {
    return pipe(value, .{ map(double), map(increment) });
}

export fn type_transition_direct(value: u32) u32 {
    const increased = increment(value);
    const even = isEven(increased);
    return score(even);
}

export fn type_transition_grouped(value: u32) u32 {
    return pipe(value, .{map(.{ increment, isEven, score })});
}

export fn type_transition_separate(value: u32) u32 {
    return pipe(value, .{ map(increment), map(isEven), map(score) });
}

fn recover(value: ?u32) u32 {
    return value orelse 7;
}

export fn keep_if_direct(value: u32) u32 {
    const kept = if (isEven(value)) value else 7;
    return increment(double(kept));
}

export fn keep_if_grouped(value: u32) u32 {
    return pipe(value, .{
        keepIf(isEven),
        map(.{ recover, double, increment }),
    });
}

export fn keep_if_separate(value: u32) u32 {
    return pipe(value, .{
        keepIf(isEven),
        map(recover),
        map(double),
        map(increment),
    });
}

export fn each_sum_direct(source: [*]const u32, len: usize) u32 {
    var total: u32 = 0;
    for (source[0..len]) |value| total +%= increment(double(value));
    return total;
}

export fn each_sum_grouped(source: [*]const u32, len: usize) u32 {
    const view = pipe(source[0..len], .{each(.{ double, increment })});
    var iterator = view.iterator();
    var total: u32 = 0;
    while (iterator.next()) |value| total +%= value;
    return total;
}

export fn each_sum_separate(source: [*]const u32, len: usize) u32 {
    const view = pipe(source[0..len], .{ each(double), each(increment) });
    var iterator = view.iterator();
    var total: u32 = 0;
    while (iterator.next()) |value| total +%= value;
    return total;
}

const Vector4 = @Vector(4, u32);

fn doubleVector(value: Vector4) Vector4 {
    return value *% @as(Vector4, @splat(2));
}

fn incrementVector(value: Vector4) Vector4 {
    return value +% @as(Vector4, @splat(1));
}

export fn vector_map_direct(source: *const [4]u32, destination: *[4]u32) void {
    const value: Vector4 = source.*;
    destination.* = incrementVector(doubleVector(value));
}

export fn vector_map_grouped(source: *const [4]u32, destination: *[4]u32) void {
    const value: Vector4 = source.*;
    destination.* = pipe(value, .{map(.{ doubleVector, incrementVector })});
}

export fn vector_map_separate(source: *const [4]u32, destination: *[4]u32) void {
    const value: Vector4 = source.*;
    destination.* = pipe(value, .{ map(doubleVector), map(incrementVector) });
}

fn checkScalar(comptime case: []const u8) !void {
    const direct = @field(@This(), case ++ "_direct");
    const grouped = @field(@This(), case ++ "_grouped");
    const separate = @field(@This(), case ++ "_separate");
    for ([_]u32{ 0, 1, 2, 42, std.math.maxInt(u32) }) |value| {
        try std.testing.expectEqual(direct(value), grouped(value));
        try std.testing.expectEqual(direct(value), separate(value));
    }
}

fn arithmetic_test() !void {
    try std.testing.expectEqual(@as(u32, 7), arithmetic_direct(3));
    try std.testing.expectEqual(std.math.maxInt(u32), arithmetic_direct(std.math.maxInt(u32)));
    try checkScalar("arithmetic");
}

fn type_transition_test() !void {
    try std.testing.expectEqual(@as(u32, 10), type_transition_direct(1));
    try std.testing.expectEqual(@as(u32, 20), type_transition_direct(2));
    try checkScalar("type_transition");
}

fn keep_if_test() !void {
    try std.testing.expectEqual(@as(u32, 9), keep_if_direct(4));
    try std.testing.expectEqual(@as(u32, 15), keep_if_direct(3));
    try checkScalar("keep_if");
}

fn each_sum_test() !void {
    try std.testing.expectEqual(@as(u32, 9), each_sum_direct(&.{ 0, 1, 2 }, 3));
    var source: [257]u32 = undefined;
    for (&source, 0..) |*value, index| value.* = @as(u32, @intCast(index)) *% 123456789;
    for (0..source.len + 1) |len| {
        try std.testing.expectEqual(each_sum_direct(&source, len), each_sum_grouped(&source, len));
        try std.testing.expectEqual(each_sum_direct(&source, len), each_sum_separate(&source, len));
    }
}

fn vector_map_test() !void {
    const sources = [_][4]u32{
        .{ 0, 1, 2, 3 },
        .{ std.math.maxInt(u32), std.math.maxInt(u32) - 1, 42, 123456789 },
    };
    for (sources) |source| {
        var expected: [4]u32 = undefined;
        var grouped: [4]u32 = undefined;
        var separate: [4]u32 = undefined;
        vector_map_direct(&source, &expected);
        vector_map_grouped(&source, &grouped);
        vector_map_separate(&source, &separate);
        for (source, expected) |value, actual| try std.testing.expectEqual(increment(double(value)), actual);
        try std.testing.expectEqualSlices(u32, &expected, &grouped);
        try std.testing.expectEqualSlices(u32, &expected, &separate);
    }
}

test "all catalog cases also agree at runtime, including empty inputs and wrapping boundaries" {
    inline for (catalog.cases ++ catalog.behavior_only_cases) |case| {
        try @field(@This(), case ++ "_test")();
    }
    inline for (catalog.assembly_cases) |case| try @field(@This(), case.name ++ "_test")();
}
