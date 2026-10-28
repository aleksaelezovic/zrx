const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u32 {
    return value + 1;
}

fn isSeven(value: u32) bool {
    return value == 7;
}

fn describe(value: bool) []const u8 {
    return if (value) "seven" else "other";
}

fn prepare() @TypeOf(map(.{ double, increment })) {
    return map(.{ double, increment });
}

test "one transformer and one-item transformer tuple are equivalent" {
    try std.testing.expectEqual(@as(u32, 6), pipe(@as(u32, 3), .{map(double)}));
    try std.testing.expectEqual(
        pipe(@as(u32, 3), .{map(double)}),
        pipe(@as(u32, 3), .{map(.{double})}),
    );
}

test "grouped and consecutive maps preserve order and type transitions" {
    const grouped = pipe(@as(u32, 3), .{map(.{ double, increment, isSeven, describe })});
    const separate = pipe(@as(u32, 3), .{
        map(double),
        map(increment),
        map(isSeven),
        map(describe),
    });
    try std.testing.expectEqual(@TypeOf(separate), @TypeOf(grouped));
    try std.testing.expectEqualStrings("seven", grouped);
    try std.testing.expectEqualStrings(grouped, separate);
    try std.testing.expectEqual(@as(u32, 8), pipe(@as(u32, 3), .{map(.{ increment, double })}));
}

test "mixed forms and named helper operators compose without nested tuples" {
    const result = pipe(@as(u32, 3), .{
        prepare(),
        map(.{ isSeven, describe }),
    });
    try std.testing.expectEqualStrings("seven", result);
}

test "ordinary Zig coercions and comptime evaluation" {
    const constant = comptime pipe(3, .{map(.{ double, increment })});
    try std.testing.expectEqual(@as(u32, 7), constant);
    const small: u8 = 3;
    try std.testing.expectEqual(@as(u32, 6), pipe(small, .{map(double)}));
}

test "result annotation with an untyped literal input" {
    const result: u32 = pipe(3, .{
        map(.{ double, increment }),
    });
    try std.testing.expectEqual(@as(u32, 7), result);
}

test "runtime inputs are evaluated normally" {
    var value: u32 = 3;
    // Taking a mutable pointer keeps the input a runtime value.
    const ptr = &value;
    ptr.* += 1;
    try std.testing.expectEqual(@as(u32, 9), pipe(value, .{map(.{ double, increment })}));
}

test "void is an explicit output and can be consumed by a typed unary function" {
    const Helpers = struct {
        fn discard(_: u32) void {}

        fn afterDiscard(_: void) u32 {
            return 42;
        }
    };
    try std.testing.expectEqual(void, @TypeOf(pipe(@as(u32, 3), .{map(Helpers.discard)})));
    try std.testing.expectEqual(
        @as(u32, 42),
        pipe(@as(u32, 3), .{map(.{ Helpers.discard, Helpers.afterDiscard })}),
    );
}

test "borrowed results retain the original storage" {
    const Helpers = struct {
        fn suffix(value: []const u8) []const u8 {
            return value[1..];
        }
    };
    var buffer = [_]u8{ 'a', 'b', 'c' };
    const result = pipe(@as([]const u8, &buffer), .{map(Helpers.suffix)});
    try std.testing.expect(result.ptr == buffer[1..].ptr);
    buffer[1] = 'x';
    try std.testing.expectEqualStrings("xc", result);
}

test "error unions are ordinary values with no implicit propagation" {
    const Helpers = struct {
        fn checked(value: u32) error{Zero}!u32 {
            return if (value == 0) error.Zero else value;
        }

        fn recover(value: error{Zero}!u32) u32 {
            return value catch 42;
        }
    };
    const result = pipe(@as(u32, 0), .{map(Helpers.checked)});
    try std.testing.expectEqual(error{Zero}!u32, @TypeOf(result));
    try std.testing.expectError(error.Zero, result);
    try std.testing.expectEqual(
        @as(u32, 42),
        pipe(@as(u32, 0), .{map(.{ Helpers.checked, Helpers.recover })}),
    );
}

test "transformers run exactly once in order in both forms" {
    const Helpers = struct {
        var log: u32 = 0;

        fn first(value: u32) u32 {
            log = log * 10 + 1;
            return value + 1;
        }

        fn second(value: u32) u32 {
            log = log * 10 + 2;
            return value * 2;
        }
    };
    Helpers.log = 0;
    const grouped = pipe(@as(u32, 3), .{map(.{ Helpers.first, Helpers.second })});
    try std.testing.expectEqual(@as(u32, 12), Helpers.log);
    Helpers.log = 0;
    const separate = pipe(@as(u32, 3), .{ map(Helpers.first), map(Helpers.second) });
    try std.testing.expectEqual(@as(u32, 12), Helpers.log);
    try std.testing.expectEqual(@as(u32, 8), grouped);
    try std.testing.expectEqual(grouped, separate);
}
