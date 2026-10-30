const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const keepIf = zrx.keepIf;
const each = zrx.each;

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u32 {
    return value + 1;
}

fn nonzero(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

const Record = struct {
    destination: *u32,

    pub fn Output(comptime _: type) type {
        return u32;
    }

    pub fn apply(self: @This(), value: u32) u32 {
        self.destination.* = value;
        return value;
    }
};

test "tryPipe returns an error union even for infallible stages" {
    const result = tryPipe(3, .{ map(double), map(increment) });
    try std.testing.expectEqual(error{}!u32, @TypeOf(result));
    try std.testing.expectEqual(@as(u32, 7), try result);
}

test "tryPipe merges initial and stage error sets and skips initial failures" {
    const Helpers = struct {
        fn bounded(value: u32) error{TooLarge}!u32 {
            return if (value > 100) error.TooLarge else value;
        }
    };
    const initial: error{Initial}!u32 = error.Initial;
    var recorded: u32 = 99;
    const result = tryPipe(initial, .{
        map(.{ nonzero, Helpers.bounded }),
        Record{ .destination = &recorded },
    });
    try std.testing.expectEqual(error{ Initial, Zero, TooLarge }!u32, @TypeOf(result));
    try std.testing.expectError(error.Initial, result);
    try std.testing.expectEqual(@as(u32, 99), recorded);
}

test "tryPipe skips later operators without rolling back earlier state changes" {
    var before: u32 = 99;
    var after: u32 = 99;
    try std.testing.expectError(error.Zero, tryPipe(0, .{
        Record{ .destination = &before },
        map(nonzero),
        Record{ .destination = &after },
    }));
    try std.testing.expectEqual(@as(u32, 0), before);
    try std.testing.expectEqual(@as(u32, 99), after);
}

test "tryPipe short-circuits inside grouped maps as it does between separate maps" {
    const Helpers = struct {
        var calls: u32 = 0;
        fn observedDouble(value: u32) u32 {
            calls += 1;
            return double(value);
        }
    };
    Helpers.calls = 0;
    const grouped = tryPipe(0, .{map(.{ nonzero, Helpers.observedDouble })});
    const separate = tryPipe(0, .{ map(nonzero), map(Helpers.observedDouble) });
    try std.testing.expectEqual(@TypeOf(grouped), @TypeOf(separate));
    try std.testing.expectError(error.Zero, grouped);
    try std.testing.expectError(error.Zero, separate);
    try std.testing.expectEqual(@as(u32, 0), Helpers.calls);
    try std.testing.expectEqual(
        try tryPipe(3, .{map(.{ nonzero, double, increment })}),
        try tryPipe(3, .{ map(nonzero), map(double), map(increment) }),
    );
}

test "ordinary pipe still passes error unions through grouped maps as values" {
    const Helpers = struct {
        fn recover(value: error{Zero}!u32) u32 {
            return value catch 42;
        }
    };
    try std.testing.expectEqual(@as(u32, 42), pipe(0, .{map(.{ nonzero, Helpers.recover })}));
}

test "tryPipe unwraps one outer error union per stage result, not nested payload errors" {
    const Inner = error{Inner}!u32;
    const Helpers = struct {
        fn nested(_: u32) error{Outer}!Inner {
            return @as(Inner, error.Inner);
        }
        fn recoverInner(value: Inner) u32 {
            return value catch 17;
        }
    };
    const result = tryPipe(3, .{map(Helpers.nested)});
    try std.testing.expectEqual(error{Outer}!Inner, @TypeOf(result));
    try std.testing.expectError(error.Inner, try result);
    try std.testing.expectEqual(@as(u32, 17), try tryPipe(3, .{
        map(.{ Helpers.nested, Helpers.recoverInner }),
    }));
    try std.testing.expectEqual(@as(u32, 17), try tryPipe(3, .{
        map(Helpers.nested),
        map(Helpers.recoverInner),
    }));
}

test "tryPipe preserves null and void; error data can be transformed or boxed" {
    const Box = struct { value: error{Data} };
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
        fn fallback(value: ?u32) u32 {
            return value orelse 99;
        }
        fn errorData(_: error{Data}) u32 {
            return 17;
        }
        fn sameError(value: Box) Box {
            return value;
        }
        fn discard(_: u32) void {}
    };
    try std.testing.expectEqual(@as(u32, 99), try tryPipe(3, .{
        keepIf(Helpers.even),
        map(Helpers.fallback),
    }));
    try std.testing.expectEqual(@as(u32, 17), try tryPipe(error.Data, .{map(Helpers.errorData)}));
    const boxed = try tryPipe(Box{ .value = error.Data }, .{map(Helpers.sameError)});
    try std.testing.expectEqual(error.Data, boxed.value);
    const result = tryPipe(3, .{map(Helpers.discard)});
    try std.testing.expectEqual(error{}!void, @TypeOf(result));
    try result;
}

test "tryPipe does not inspect error unions inside lazy sequence elements" {
    const source = [_]u32{ 0, 2 };
    const result = try tryPipe(&source, .{each(nonzero)});
    var cursor = result.iterator();
    try std.testing.expectError(error.Zero, cursor.next().?);
    try std.testing.expectEqual(@as(u32, 2), try cursor.next().?);
    try std.testing.expectEqual(@as(?error{Zero}!u32, null), cursor.next());
}

test "resource cleanup remains with the caller on tryPipe failure" {
    const Helpers = struct {
        fn fail(_: []u8) error{Failed}![]u8 {
            return error.Failed;
        }
    };
    const owned = try std.testing.allocator.alloc(u8, 4);
    defer std.testing.allocator.free(owned);
    try std.testing.expectError(error.Failed, tryPipe(owned, .{map(Helpers.fail)}));
    owned[0] = 7;
    try std.testing.expectEqual(@as(u8, 7), owned[0]);
}
