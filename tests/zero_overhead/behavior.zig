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

test "taken" {
    for (inputs) |items| for ([_]usize{ 0, 1, 3, 100 }) |limit| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.taken(true, items, limit, &with);
        cases.taken(false, items, limit, &without);
        try std.testing.expectEqual(without, with);
    };
}

test "scanned" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.scanned(true, items, &with);
        cases.scanned(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "skipped" {
    for (inputs) |items| for ([_]usize{ 0, 1, 5, 100 }) |count| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.skipped(true, items, count, &with);
        cases.skipped(false, items, count, &without);
        try std.testing.expectEqual(without, with);
    };
}

test "takenWhile" {
    for (inputs) |items| for ([_]u32{ 0, 4, 101, std.math.maxInt(u32) }) |below| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.takenWhile(true, items, below, &with);
        cases.takenWhile(false, items, below, &without);
        try std.testing.expectEqual(without, with);
    };
}

test "tapped" {
    for (inputs) |items| {
        var with: u64 = 5;
        var without: u64 = 5;
        cases.tapped(true, items, &with);
        cases.tapped(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}
