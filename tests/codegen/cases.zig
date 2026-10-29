const std = @import("std");
const zrx = @import("zrx");
const catalog = @import("catalog.zig");
const pipe = zrx.pipe;
const map = zrx.map;
const keepIf = zrx.keepIf;
const each = zrx.each;
const fold = zrx.fold;
const tryFold = zrx.tryFold;
const tap = zrx.tap;
const tapWith = zrx.tapWith;
const tryPipe = zrx.tryPipe;

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

fn sum(total: u32, value: u32) u32 {
    return total +% value;
}

export fn fold_sum_direct(source: [*]const u32, len: usize, initial: u32) u32 {
    var total = initial;
    for (source[0..len]) |value| total = sum(total, increment(double(value)));
    return total;
}

export fn fold_sum_grouped(source: [*]const u32, len: usize, initial: u32) u32 {
    return pipe(source[0..len], .{ each(.{ double, increment }), fold(initial, sum) });
}

export fn fold_sum_separate(source: [*]const u32, len: usize, initial: u32) u32 {
    return pipe(source[0..len], .{ each(double), each(increment), fold(initial, sum) });
}

fn checkedSum(total: u32, value: u32) error{Rejected}!u32 {
    if (value > 100) return error.Rejected;
    return sum(total, value);
}

export fn try_fold_direct(source: [*]const u32, len: usize, initial: u32, output: *u32) bool {
    var total = initial;
    for (source[0..len]) |value| {
        total = checkedSum(total, increment(double(value))) catch return false;
    }
    output.* = total;
    return true;
}

export fn try_fold_grouped(source: [*]const u32, len: usize, initial: u32, output: *u32) bool {
    const total = pipe(source[0..len], .{
        each(.{ double, increment }),
        tryFold(initial, checkedSum),
    }) catch return false;
    output.* = total;
    return true;
}

export fn try_fold_separate(source: [*]const u32, len: usize, initial: u32, output: *u32) bool {
    const total = pipe(source[0..len], .{
        each(double),
        each(increment),
        tryFold(initial, checkedSum),
    }) catch return false;
    output.* = total;
    return true;
}

fn fold_sum_test() !void {
    var source: [257]u32 = undefined;
    for (&source, 0..) |*value, index| value.* = @as(u32, @intCast(index)) *% 123456789;
    for ([_]u32{ 0, 7, std.math.maxInt(u32) }) |initial| {
        for (0..source.len + 1) |len| {
            const expected = fold_sum_direct(&source, len, initial);
            try std.testing.expectEqual(expected, fold_sum_grouped(&source, len, initial));
            try std.testing.expectEqual(expected, fold_sum_separate(&source, len, initial));
        }
    }
}

fn try_fold_test() !void {
    var source: [257]u32 = undefined;
    for (&source, 0..) |*value, index| value.* = @intCast(index);
    for ([_]u32{ 0, 7, std.math.maxInt(u32) }) |initial| {
        for (0..source.len + 1) |len| {
            var expected: u32 = 99;
            var grouped: u32 = 99;
            var separate: u32 = 99;
            const accepted = try_fold_direct(&source, len, initial, &expected);
            try std.testing.expectEqual(accepted, try_fold_grouped(&source, len, initial, &grouped));
            try std.testing.expectEqual(accepted, try_fold_separate(&source, len, initial, &separate));
            try std.testing.expectEqual(expected, grouped);
            try std.testing.expectEqual(expected, separate);
        }
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

fn record(destination: *u32, value: u32) void {
    destination.* = value;
}

export fn tap_record_direct(value: u32, destination: *u32) u32 {
    record(destination, value);
    return increment(double(value));
}

export fn tap_record_grouped(value: u32, destination: *u32) u32 {
    return pipe(value, .{
        tapWith(destination, record),
        map(.{ double, increment }),
    });
}

export fn tap_record_separate(value: u32, destination: *u32) u32 {
    return pipe(value, .{
        tapWith(destination, record),
        map(double),
        map(increment),
    });
}

fn checked(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn reject(rejected: bool, _: u32) error{Rejected}!void {
    if (rejected) return error.Rejected;
}

export fn try_flow_direct(value: u32, destination: *u32, rejected: bool) u32 {
    const accepted = double(checked(value) catch return 0);
    record(destination, accepted);
    reject(rejected, accepted) catch return 0;
    return increment(accepted);
}

export fn try_flow_grouped(value: u32, destination: *u32, rejected: bool) u32 {
    return tryPipe(value, .{
        map(.{ checked, double }),
        tapWith(destination, record),
        tapWith(rejected, reject),
        map(increment),
    }) catch 0;
}

export fn try_flow_separate(value: u32, destination: *u32, rejected: bool) u32 {
    return tryPipe(value, .{
        map(checked),
        map(double),
        tapWith(destination, record),
        tapWith(rejected, reject),
        map(increment),
    }) catch 0;
}

fn tap_record_test() !void {
    for ([_]u32{ 0, 1, 42, std.math.maxInt(u32) }) |value| {
        var direct: u32 = 0;
        var grouped: u32 = 0;
        var separate: u32 = 0;
        const expected = tap_record_direct(value, &direct);
        try std.testing.expectEqual(expected, tap_record_grouped(value, &grouped));
        try std.testing.expectEqual(expected, tap_record_separate(value, &separate));
        try std.testing.expectEqual(value, direct);
        try std.testing.expectEqual(direct, grouped);
        try std.testing.expectEqual(direct, separate);
    }
}

fn visit(value: *u32) void {
    value.* +%= 1;
}

fn read(value: *u32) u32 {
    return value.*;
}

export fn tap_visit_direct(value: *u32) u32 {
    visit(value);
    return increment(double(read(value)));
}

export fn tap_visit_grouped(value: *u32) u32 {
    return pipe(value, .{
        tap(visit),
        map(.{ read, double, increment }),
    });
}

export fn tap_visit_separate(value: *u32) u32 {
    return pipe(value, .{
        tap(visit),
        map(read),
        map(double),
        map(increment),
    });
}

fn tap_visit_test() !void {
    for ([_]u32{ 0, 1, 42, std.math.maxInt(u32) }) |value| {
        var direct = value;
        var grouped = value;
        var separate = value;
        const expected = tap_visit_direct(&direct);
        try std.testing.expectEqual(expected, tap_visit_grouped(&grouped));
        try std.testing.expectEqual(expected, tap_visit_separate(&separate));
        try std.testing.expectEqual(increment(value), direct);
        try std.testing.expectEqual(direct, grouped);
        try std.testing.expectEqual(direct, separate);
    }
}

fn try_flow_test() !void {
    for ([_]u32{ 0, 1, 42, std.math.maxInt(u32) }) |value| {
        for ([_]bool{ false, true }) |rejected| {
            var direct: u32 = 99;
            var grouped: u32 = 99;
            var separate: u32 = 99;
            const expected = try_flow_direct(value, &direct, rejected);
            try std.testing.expectEqual(expected, try_flow_grouped(value, &grouped, rejected));
            try std.testing.expectEqual(expected, try_flow_separate(value, &separate, rejected));
            try std.testing.expectEqual(if (value == 0) @as(u32, 99) else double(value), direct);
            try std.testing.expectEqual(direct, grouped);
            try std.testing.expectEqual(direct, separate);
        }
    }
}

test "all catalog cases also agree at runtime, including empty inputs and wrapping boundaries" {
    inline for (catalog.cases ++ catalog.behavior_only_cases) |case| {
        try @field(@This(), case ++ "_test")();
    }
    inline for (catalog.assembly_cases) |case| try @field(@This(), case.name ++ "_test")();
}
