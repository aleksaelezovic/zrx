const std = @import("std");
const zrx = @import("zrx");
const catalog = @import("catalog.zig");

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
    return zrx.pipe(value, .{zrx.map(.{ double, increment })});
}

export fn arithmetic_separate(value: u32) u32 {
    return zrx.pipe(value, .{ zrx.map(double), zrx.map(increment) });
}

export fn type_transition_direct(value: u32) u32 {
    const increased = increment(value);
    const even = isEven(increased);
    return score(even);
}

export fn type_transition_grouped(value: u32) u32 {
    return zrx.pipe(value, .{zrx.map(.{ increment, isEven, score })});
}

export fn type_transition_separate(value: u32) u32 {
    return zrx.pipe(value, .{ zrx.map(increment), zrx.map(isEven), zrx.map(score) });
}

test "codegen fixtures also agree at runtime, including wrapping boundaries" {
    try std.testing.expectEqual(@as(u32, 7), arithmetic_direct(3));
    try std.testing.expectEqual(std.math.maxInt(u32), arithmetic_direct(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 10), type_transition_direct(1));
    try std.testing.expectEqual(@as(u32, 20), type_transition_direct(2));
    inline for (catalog.cases) |case| {
        const direct = @field(@This(), case ++ "_direct");
        const grouped = @field(@This(), case ++ "_grouped");
        const separate = @field(@This(), case ++ "_separate");
        for ([_]u32{ 0, 1, 2, 42, std.math.maxInt(u32) }) |value| {
            try std.testing.expectEqual(direct(value), grouped(value));
            try std.testing.expectEqual(direct(value), separate(value));
        }
    }
}
