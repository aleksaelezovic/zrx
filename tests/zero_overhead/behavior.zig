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

test "routedFound, routedGuarded" {
    for (inputs) |items| inline for (.{ cases.routedFound, cases.routedGuarded }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, items, &with);
        case(false, items, &without);
        try std.testing.expectEqual(without, with);
    };
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

test "recovered, recoveredInto, recoveredOnce" {
    for (inputs) |items| inline for (.{ cases.recovered, cases.recoveredInto, cases.recoveredOnce }) |case| {
        var with: struct { u32, u64 } = .{ 0, 0 };
        var without: struct { u32, u64 } = .{ 0, 0 };
        case(true, items, &with[0], &with[1]);
        case(false, items, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
    };
}

test "recoveredOrFailed" {
    for (inputs) |items| {
        var with: struct { u32, u64 } = .{ 0, 0 };
        var without: struct { u32, u64 } = .{ 0, 0 };
        const failed = cases.recoveredOrFailed(true, items, &with[0], &with[1]);
        try std.testing.expectEqual(cases.recoveredOrFailed(false, items, &without[0], &without[1]), failed);
        try std.testing.expectEqual(without, with);
    }
}

test "rescued" {
    for (inputs) |items| {
        var with: struct { u32, u64, bool } = .{ 0, 0, false };
        var without: struct { u32, u64, bool } = .{ 0, 0, false };
        cases.rescued(true, items, &with[0], &with[1], &with[2]);
        cases.rescued(false, items, &without[0], &without[1], &without[2]);
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

test "batched" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.batched(true, items, &with);
        cases.batched(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "withResource" {
    for (inputs) |items| {
        var with: struct { u32, u32, u64 } = .{ 3, 7, 99 };
        var without: struct { u32, u32, u64 } = .{ 3, 7, 98 };
        cases.withResource(true, items, &with[0], &with[1], &with[2]);
        cases.withResource(false, items, &without[0], &without[1], &without[2]);
        try std.testing.expectEqual(without, with);
    }
}

test "withBindings" {
    for (inputs) |items| {
        var with: struct { u32, u32, u64 } = .{ 3, 7, 99 };
        var without: struct { u32, u32, u64 } = .{ 3, 7, 98 };
        cases.withBindings(true, items, 5, &with[0], &with[1], &with[2]);
        cases.withBindings(false, items, 5, &without[0], &without[1], &without[2]);
        try std.testing.expectEqual(without, with);
    }
}

test "printed" {
    for (inputs) |items| {
        var with_bytes: [256]u8 = undefined;
        var without_bytes: [256]u8 = undefined;
        var with: std.Io.Writer = .fixed(&with_bytes);
        var without: std.Io.Writer = .fixed(&without_bytes);
        var failed: [2]bool = .{ false, false };
        cases.printed(true, items, &with, &failed[0]);
        cases.printed(false, items, &without, &failed[1]);
        try std.testing.expectEqual([2]bool{ false, false }, failed);
        try std.testing.expectEqualStrings(without.buffered(), with.buffered());
    }
    // A writer that runs out of room fails both the same way.
    var small_with: [3]u8 = undefined;
    var small_without: [3]u8 = undefined;
    var with: std.Io.Writer = .fixed(&small_with);
    var without: std.Io.Writer = .fixed(&small_without);
    var failed: [2]bool = .{ false, false };
    cases.printed(true, inputs[3], &with, &failed[0]);
    cases.printed(false, inputs[3], &without, &failed[1]);
    try std.testing.expectEqual([2]bool{ true, true }, failed);
}

test "written" {
    for (inputs) |items| {
        var with_bytes: [256]u8 = undefined;
        var without_bytes: [256]u8 = undefined;
        var with: std.Io.Writer = .fixed(&with_bytes);
        var without: std.Io.Writer = .fixed(&without_bytes);
        var failed: [2]bool = .{ false, false };
        cases.written(true, items, &with, &failed[0]);
        cases.written(false, items, &without, &failed[1]);
        try std.testing.expectEqual([2]bool{ false, false }, failed);
        try std.testing.expectEqualStrings(without.buffered(), with.buffered());
    }
    var small_with: [3]u8 = undefined;
    var small_without: [3]u8 = undefined;
    var with: std.Io.Writer = .fixed(&small_with);
    var without: std.Io.Writer = .fixed(&small_without);
    var failed: [2]bool = .{ false, false };
    cases.written(true, inputs[3], &with, &failed[0]);
    cases.written(false, inputs[3], &without, &failed[1]);
    try std.testing.expectEqual([2]bool{ true, true }, failed);
}

test "reduced" {
    const rows = [_][4]u32{ .{ 1, 6, 7, 2 }, .{ 0, 0, 0, 0 }, .{ 100, 5, 6, 1000 } };
    for ([_][]const [4]u32{ &.{}, rows[0..1], &rows }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.reduced(true, some, &with);
        cases.reduced(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "fellBack" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.fellBack(true, items, &with);
        cases.fellBack(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "required, requiredFound" {
    for (inputs) |items| inline for (.{ cases.required, cases.requiredFound }) |case| {
        var with: struct { u32, u64 } = .{ 0, 0 };
        var without: struct { u32, u64 } = .{ 0, 0 };
        case(true, items, &with[0], &with[1]);
        case(false, items, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
    };
}

fn textsOf(comptime strings: []const []const u8) [strings.len]cases.Text {
    var texts: [strings.len]cases.Text = undefined;
    for (&texts, strings) |*text, string| text.* = .{ .ptr = string.ptr, .len = string.len };
    return texts;
}

test "namesCounted, pathsRouted, readingsRequired" {
    const texts = comptime textsOf(&.{
        "api-gw",                          "",              "billing v2",        "auth_1",            "/items/42", "/items/",
        "/items/4x",                       "/items/007",    "/items/4294967295", "/items/4294967296", "17,-4",     "17,4",
        "18446744073709551615,2147483647", "1,-2147483648", "1,2147483648",      "1,",                ",1",        "1,2,3",
        "+1,2",                            "1,+2",          "1_0,2",
    });
    for ([_][]const cases.Text{ &.{}, texts[0..4], &texts }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.namesCounted(true, some, &with);
        cases.namesCounted(false, some, &without);
        try std.testing.expectEqual(without, with);

        var routed: [2]u64 = .{ 99, 98 };
        var by_hand: [2]u64 = .{ 97, 96 };
        cases.pathsRouted(true, some, &routed[0], &routed[1]);
        cases.pathsRouted(false, some, &by_hand[0], &by_hand[1]);
        try std.testing.expectEqual(by_hand, routed);

        var required: struct { u32, u64 } = .{ 0, 0 };
        var parsed: struct { u32, u64 } = .{ 0, 0 };
        cases.readingsRequired(true, some, &required[0], &required[1]);
        cases.readingsRequired(false, some, &parsed[0], &parsed[1]);
        try std.testing.expectEqual(parsed, required);
    }
}

test "rowsRouted" {
    const texts = [_][]const u8{
        "north,17",            "south,-4",      "",             "north",   "north,",    ",4",   "northerly,1",
        "abcdefgh,2147483647", "x,-2147483648", "x,2147483648", "North,1", "north,1,2", "n,+1", "east,7 ",
        "west,0",
    };
    var rows: [texts.len]cases.Row = undefined;
    for (&rows, texts) |*row, text| row.* = try cases.Row.from(text);
    for ([_][]const cases.Row{ &.{}, rows[0..3], &rows }) |some| {
        var with: struct { u64, cases.Sensor, u64 } = .{ 99, try cases.Sensor.from("none"), 98 };
        var without: struct { u64, cases.Sensor, u64 } = .{ 99, try cases.Sensor.from("none"), 98 };
        cases.rowsRouted(true, some, &with[0], &with[1], &with[2]);
        cases.rowsRouted(false, some, &without[0], &without[1], &without[2]);
        try std.testing.expectEqual(without[0], with[0]);
        try std.testing.expectEqualStrings(without[1].text(), with[1].text());
        try std.testing.expectEqual(without[2], with[2]);
    }
    var sum: u64 = 0;
    var sensor = try cases.Sensor.from("none");
    var others: u64 = 0;
    cases.rowsRouted(true, &rows, &sum, &sensor, &others);
    try std.testing.expectEqualStrings("west", sensor.text());
    try std.testing.expectEqual(10, others);
}

test "nested" {
    const values = [_]u32{ 1, 6, 7, 2, 100, 5, 6, 1000 };
    const groups = [_]cases.Group{
        .{ .ptr = &values, .len = 4, .weight = 3 },
        .{ .ptr = &values, .len = 0, .weight = 7 },
        .{ .ptr = values[2..].ptr, .len = 6, .weight = 1 },
    };
    for ([_][]const cases.Group{ &.{}, groups[0..1], &groups }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.nested(true, some, &with);
        cases.nested(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "attempted" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.attempted(true, items, &with);
        cases.attempted(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "attemptedCapped" {
    // The last input holds values over the cap: both variants fail there
    // and leave the result as it was.
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 99;
        const passed = cases.attemptedCapped(false, items, &without);
        try std.testing.expectEqual(passed, cases.attemptedCapped(true, items, &with));
        try std.testing.expectEqual(without, with);
    }
    var untouched: u64 = 99;
    try std.testing.expect(!cases.attemptedCapped(true, inputs[3], &untouched));
    try std.testing.expectEqual(@as(u64, 99), untouched);
}
