const std = @import("std");
// Internal cursor/materialization fixtures; public terminal lifecycle is tested
// through run in terminals.zig.
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
const collectInto = zrx.collectInto;
const collectAlloc = zrx.collectAlloc;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u32 {
    return value + 1;
}

fn optionalLength(value: ?u32) u32 {
    return value orelse 99;
}

test "keepIf returns an optional and never silently skips the next stage" {
    try std.testing.expectEqual(@as(?u32, 4), pipe(4, .{keepIf(isEven)}));
    try std.testing.expectEqual(@as(?u32, null), pipe(3, .{keepIf(isEven)}));
    try std.testing.expectEqual(
        @as(u32, 99),
        pipe(3, .{ keepIf(isEven), map(optionalLength) }),
    );
    const small: u8 = 4;
    try std.testing.expectEqual(@as(?u32, 4), pipe(small, .{keepIf(isEven)}));
    const constant = comptime pipe(4, .{keepIf(isEven)});
    try std.testing.expectEqual(@as(?u32, 4), constant);
}

test "map remains a whole-value operation for arrays and slices" {
    const Helpers = struct {
        fn arrayLength(_: [3]u32) usize {
            return 3;
        }
        fn sliceLength(values: []const u32) usize {
            return values.len;
        }
    };
    const values = [_]u32{ 1, 2, 3 };
    try std.testing.expectEqual(@as(usize, 3), pipe(values, .{map(Helpers.arrayLength)}));
    try std.testing.expectEqual(@as(usize, 3), pipe(&values, .{map(Helpers.sliceLength)}));
}

test "keepIf may keep a whole slice or nested optional as a scalar value" {
    const Helpers = struct {
        fn nonempty(value: []const u32) bool {
            return value.len != 0;
        }
        fn always(_: ?u32) bool {
            return true;
        }
    };
    const source = [_]u32{ 1, 2 };
    const kept = pipe(&source, .{keepIf(Helpers.nonempty)}).?;
    try std.testing.expect(kept.ptr == source[0..].ptr);
    const nested = pipe(@as(?u32, null), .{keepIf(Helpers.always)});
    try std.testing.expect(nested != null);
    try std.testing.expect(nested.? == null);
}

test "filter and each are lazy and run only as far as the cursor consumes" {
    const Helpers = struct {
        var predicates: usize = 0;
        var transforms: usize = 0;

        fn even(value: u32) bool {
            predicates += 1;
            return isEven(value);
        }
        fn twice(value: u32) u32 {
            transforms += 1;
            return double(value);
        }
    };
    Helpers.predicates = 0;
    Helpers.transforms = 0;
    const values = [_]u32{ 1, 2, 3, 4 };
    const view = pipe(&values, .{ filter(Helpers.even), each(Helpers.twice) });
    try std.testing.expectEqual(@as(usize, 0), Helpers.predicates);
    try std.testing.expectEqual(@as(usize, 0), Helpers.transforms);
    var cursor = view.iterator();
    try std.testing.expectEqual(@as(?u32, 4), cursor.next());
    try std.testing.expectEqual(@as(usize, 2), Helpers.predicates);
    try std.testing.expectEqual(@as(usize, 1), Helpers.transforms);
    try std.testing.expectEqual(@as(?u32, 8), cursor.next());
    try std.testing.expectEqual(@as(?u32, null), cursor.next());
    try std.testing.expectEqual(@as(?u32, null), cursor.next());
    try std.testing.expectEqual(@as(usize, 4), Helpers.predicates);
    try std.testing.expectEqual(@as(usize, 2), Helpers.transforms);
}

test "views reread borrowed storage and restart from the beginning" {
    var values = [_]u32{ 1, 2, 3, 4 };
    const view = pipe(values[0..], .{filter(isEven)});
    var first = view.iterator();
    try std.testing.expectEqual(@as(?u32, 2), first.next());
    var copy = first;
    try std.testing.expectEqual(@as(?u32, 4), copy.next());
    try std.testing.expectEqual(@as(?u32, 4), first.next());
    values[0] = 6;
    var second = view.iterator();
    try std.testing.expectEqual(@as(?u32, 6), second.next());
}

test "slice sources and mixed views compose with both each forms" {
    const values = [_]u32{ 1, 2, 3, 4 };
    var grouped_storage: [4]u32 = undefined;
    var separate_storage: [4]u32 = undefined;
    const slice: []const u32 = &values;
    const grouped = try pipe(slice, .{
        filter(isEven),
        each(.{ double, increment }),
        collectInto(&grouped_storage),
    });
    const separate = try pipe(slice, .{
        filter(isEven),
        each(double),
        each(.{increment}),
        collectInto(&separate_storage),
    });
    try std.testing.expectEqualSlices(u32, &.{ 5, 9 }, grouped);
    try std.testing.expectEqualSlices(u32, grouped, separate);
    try std.testing.expect(grouped.ptr == grouped_storage[0..].ptr);
}

test "each type transitions, filters after maps, and normal argument coercions" {
    const Helpers = struct {
        fn widen(value: u32) u64 {
            return value;
        }
        fn large(value: u64) bool {
            return value > 3;
        }
    };
    const values = [_]u8{ 1, 2, 3 };
    var output: [3]u64 = undefined;
    const result = try pipe(&values, .{
        each(.{ double, Helpers.widen }),
        filter(Helpers.large),
        collectInto(&output),
    });
    try std.testing.expectEqualSlices(u64, &.{ 4, 6 }, result);
}

test "collectInto keeps the unused suffix and reports overflow without truncation" {
    const source = [_]u32{ 1, 2, 3 };
    var output = [_]u32{ 99, 99, 99, 99 };
    const result = try pipe(&source, .{collectInto(output[0..])});
    try std.testing.expectEqualSlices(u32, &source, result);
    try std.testing.expectEqual(@as(u32, 99), output[3]);
    var short: [2]u32 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, pipe(&source, .{collectInto(&short)}));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, &short);
}

test "overflow evaluates exactly one additional output element" {
    const Helpers = struct {
        var calls: usize = 0;
        fn count(value: u32) u32 {
            calls += 1;
            return value;
        }
    };
    Helpers.calls = 0;
    const source = [_]u32{ 1, 2, 3, 4 };
    var storage: [1]u32 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, pipe(&source, .{
        each(Helpers.count),
        collectInto(&storage),
    }));
    try std.testing.expectEqual(@as(usize, 2), Helpers.calls);
}

test "empty input, all-rejected input, exact capacity, and empty buffers" {
    const empty = [_]u32{};
    const rejected = [_]u32{ 1, 3, 5 };
    const accepted = [_]u32{ 2, 4 };
    var no_storage: [0]u32 = .{};
    var exact: [2]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try pipe(&empty, .{collectInto(&no_storage)})).len);
    try std.testing.expectEqual(@as(usize, 0), (try pipe(&rejected, .{
        filter(isEven),
        collectInto(&no_storage),
    })).len);
    try std.testing.expectEqualSlices(u32, &accepted, try pipe(&accepted, .{collectInto(&exact)}));
    try std.testing.expectError(error.NoSpaceLeft, pipe(&accepted, .{collectInto(&no_storage)}));
}

test "optional and error-union elements are not dropped or unwrapped" {
    const Helpers = struct {
        fn optional(value: u32) ?u32 {
            return if (isEven(value)) value else null;
        }
        fn checked(value: u32) error{Odd}!u32 {
            return if (isEven(value)) value else error.Odd;
        }
    };
    const values = [_]u32{ 1, 2 };
    var optionals: [2]?u32 = undefined;
    var errors: [2]error{Odd}!u32 = undefined;
    const optional_result = try pipe(&values, .{
        each(Helpers.optional),
        collectInto(&optionals),
    });
    try std.testing.expectEqualSlices(?u32, &.{ null, 2 }, optional_result);
    const error_result = try pipe(&values, .{
        each(Helpers.checked),
        collectInto(&errors),
    });
    try std.testing.expectEqual(@as(usize, 2), error_result.len);
    try std.testing.expectError(error.Odd, error_result[0]);
    try std.testing.expectEqual(@as(u32, 2), try error_result[1]);
}

test "collectAlloc uses the explicit allocator and returns independently owned storage" {
    var values = [_]u32{ 1, 2, 3, 4 };
    const view = pipe(&values, .{ filter(isEven), each(double) });
    const owned = try pipe(view, .{collectAlloc(std.testing.allocator)});
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualSlices(u32, &.{ 4, 8 }, owned);
    values[1] = 6;
    try std.testing.expectEqualSlices(u32, &.{ 4, 8 }, owned);
    const again = try pipe(view, .{collectAlloc(std.testing.allocator)});
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualSlices(u32, &.{ 12, 8 }, again);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var values: [80]u32 = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(index);
    const owned = try pipe(&values, .{
        filter(isEven),
        each(double),
        collectAlloc(allocator),
    });
    defer allocator.free(owned);
    try std.testing.expectEqual(@as(usize, 40), owned.len);
}

test "allocation failures free all intermediate collection storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
    const empty = [_]u32{};
    const owned = try pipe(&empty, .{collectAlloc(std.testing.allocator)});
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqual(@as(usize, 0), owned.len);
}

test "runtime custom operators receive explicit caller-owned state" {
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
    var recorded: u32 = 0;
    const result = pipe(3, .{
        map(double),
        Record{ .destination = &recorded },
        map(increment),
    });
    try std.testing.expectEqual(@as(u32, 6), recorded);
    try std.testing.expectEqual(@as(u32, 7), result);
}

test "custom operators can receive std.Io directly without a zrx wrapper" {
    const ReceiveIo = struct {
        io: std.Io,
        received: *?std.Io,

        pub fn Output(comptime _: type) type {
            return u32;
        }
        pub fn apply(self: @This(), value: u32) u32 {
            self.received.* = self.io;
            return value;
        }
    };
    var received: ?std.Io = null;
    const result = pipe(3, .{ReceiveIo{ .io = std.testing.io, .received = &received }});
    try std.testing.expectEqual(@as(u32, 3), result);
    try std.testing.expect(received.?.userdata == std.testing.io.userdata);
    try std.testing.expect(received.?.vtable == std.testing.io.vtable);
}
