//! Both variants of every zero-overhead fixture must compute the same thing;
//! otherwise comparing their code would mean nothing.
const std = @import("std");
const cases = @import("cases");

const inputs = [_][]const u32{
    &.{},
    &.{7},
    &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },
    &.{ 0, 100, 3, 250, 9, 10, 4096, 2, 2, 2, 99, 1_000_000 },
};

test "sumScaled, nestedProvide" {
    for (inputs) |items| for ([_]u32{ 0, 1, 3 }) |by| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.sumScaled(true, items, by, &with);
        cases.sumScaled(false, items, by, &without);
        try std.testing.expectEqual(without, with);
        cases.nestedProvide(true, items, by, &with);
        cases.nestedProvide(false, items, by, &without);
        try std.testing.expectEqual(without, with);
    };
}

test "routed" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.routed(true, items, &with);
        cases.routed(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "branched" {
    for (inputs) |items| {
        var with: [2]u64 = .{ 99, 98 };
        var without: [2]u64 = .{ 97, 96 };
        cases.branched(true, items, &with[0], &with[1]);
        cases.branched(false, items, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
    }
}

test "flattened" {
    const rows = [_][4]u32{ .{ 1, 6, 7, 2 }, .{ 0, 0, 0, 0 }, .{ 100, 5, 6, 1000 } };
    for ([_][]const [4]u32{ &.{}, rows[0..1], &rows }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.flattened(true, some, &with);
        cases.flattened(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "recovered" {
    for (inputs) |items| {
        var with: struct { u32, u64 } = .{ 0, 0 };
        var without: struct { u32, u64 } = .{ 0, 0 };
        cases.recovered(true, items, &with[0], &with[1]);
        cases.recovered(false, items, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
    }
}

test "combined" {
    const orders = [_]cases.Order{
        .{ .id = 1, .price = 100 }, .{ .id = 2, .price = 500 }, .{ .id = 3, .price = 99 },
        .{ .id = 5, .price = 250 }, .{ .id = 7, .price = 0 },
    };
    for ([_][]const cases.Order{ &.{}, orders[0..2], &orders }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.combined(true, some, &with);
        cases.combined(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "taken" {
    for (inputs) |items| for ([_]usize{ 0, 1, 3, 100 }) |limit| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.taken(true, items, limit, &with);
        cases.taken(false, items, limit, &without);
        try std.testing.expectEqual(without, with);
    };
}
