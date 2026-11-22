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

test "exited, judged, refused" {
    const too_large: []const u32 = &.{ 5, 4096, 7 };
    for (inputs ++ .{too_large}) |items| {
        var with: struct { u64, cases.Exit } = .{ 0, .{} };
        var without: struct { u64, cases.Exit } = .{ 0, .{} };
        cases.exited(true, items, &with[0], &with[1]);
        cases.exited(false, items, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
    }
    // A status that is there already is raised, or left where it is higher.
    for ([_]u8{ 0, 1, 9 }) |before| {
        var with: struct { u64, cases.Exit } = .{ 0, .{ .code = before } };
        var without: struct { u64, cases.Exit } = .{ 0, .{ .code = before } };
        cases.judged(true, too_large, &with[0], &with[1]);
        cases.judged(false, too_large, &without[0], &without[1]);
        try std.testing.expectEqual(without, with);
        try std.testing.expectEqual(@max(before, 3), with[1].code);
        try std.testing.expectEqual(4108, with[0]);
        cases.judged(true, too_large[0..1], &with[0], &with[1]);
        try std.testing.expectEqual(@max(before, 3), with[1].code);
    }
    // Room for the line, room for a part of it, and none.
    for ([_]usize{ 64, 9, 0 }) |room| {
        var with_bytes: [64]u8 = undefined;
        var without_bytes: [64]u8 = undefined;
        var with_writer: std.Io.Writer = .fixed(with_bytes[0..room]);
        var without_writer: std.Io.Writer = .fixed(without_bytes[0..room]);
        var with: cases.Exit = .{};
        var without: cases.Exit = .{};
        cases.refused(true, error.InvalidArguments, &with, &with_writer);
        cases.refused(false, error.InvalidArguments, &without, &without_writer);
        try std.testing.expectEqual(without, with);
        try std.testing.expectEqual(2, with.code);
        try std.testing.expectEqualStrings(without_writer.buffered(), with_writer.buffered());
        if (room == 64) try std.testing.expectEqualStrings("fatal: InvalidArguments\n", with_writer.buffered());
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

/// An `Io` whose clocks say the next of a list of times, in milliseconds,
/// every time one is read. One at a time: its state is global.
const Scripted = struct {
    var vtable: std.Io.VTable = undefined;
    var times: []const i64 = &.{};
    var read: usize = 0;

    fn over(script: []const i64) std.Io {
        vtable = std.testing.io.vtable.*;
        vtable.now = now;
        times = script;
        read = 0;
        return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    }

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        defer read += 1;
        return std.Io.Timestamp.zero.addDuration(.fromMilliseconds(times[read % times.len]));
    }
};

test "stamped, throttled" {
    // With a window of 100 ms, the items read at 0, 100, 200, 450, 550, 700
    // and 900 pass.
    const script = [_]i64{ 0, 40, 100, 130, 199, 200, 450, 460, 549, 550, 700, 701, 900 };
    for (inputs) |items| inline for (.{ cases.stamped, cases.throttled }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, items, Scripted.over(&script), &with);
        case(false, items, Scripted.over(&script), &without);
        try std.testing.expectEqual(without, with);
    };
    var passed: u64 = 0;
    cases.throttled(true, inputs[2], Scripted.over(&script), &passed);
    try std.testing.expectEqual(@as(u64, 1 + 3 + 6 + 7 + 10 + 11 + 13), passed);
    var summed: u64 = 0;
    cases.stamped(true, inputs[1], Scripted.over(script[1..]), &summed);
    try std.testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms + 7), summed);
    // Around the ends of the 63 bits the throttle counts in, which are at
    // 0 and at 9223372036854 ms and a part of one: the loop by hand reads
    // a clock outside them as the stage does.
    const far = [_]i64{ -7, 0, 99, 100, 9223372036800, 9223372036854, 9223372036855, std.math.maxInt(i64), std.math.maxInt(i64) };
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.throttled(true, items, Scripted.over(&far), &with);
        cases.throttled(false, items, Scripted.over(&far), &without);
        try std.testing.expectEqual(without, with);
    }
    var kept: u64 = 0;
    cases.throttled(true, inputs[2][0..far.len], Scripted.over(&far), &kept);
    try std.testing.expectEqual(@as(u64, 1 + 4 + 5), kept);
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

test "referencesScanned" {
    var rows: [5]cases.Row = undefined;
    for (&rows, [_][]const u8{ "north", "South", "", "east", "we st" }) |*row, text| row.* = try cases.Row.from(text);
    var pointers: [rows.len]*const cases.Row = undefined;
    for (&pointers, &rows) |*pointer, *row| pointer.* = row;
    for ([_][]const *const cases.Row{ &.{}, pointers[0..2], &pointers }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.referencesScanned(true, some, &with);
        cases.referencesScanned(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
    var sum: u64 = 0;
    cases.referencesScanned(true, &pointers, &sum);
    try std.testing.expectEqual(9, sum);
}

test "trimmedLength, longestColumns, longestWords" {
    const texts = comptime textsOf(&.{
        "",     " ",          "a",   " a",        "a\t",        " \t a b \t ", "a,b,c",        "a,,c",   ",", ",a,",
        "abc,", "one, three", " , ", "\t\ttab\t", "a  b\t\tcd", "    ",        "x,yy,zzz,,yy", "no-sep",
    });
    for ([_][]const cases.Text{ &.{}, texts[0..5], &texts }) |some| inline for (.{ cases.trimmedLength, cases.longestColumns, cases.longestWords }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, some, &with);
        case(false, some, &without);
        try std.testing.expectEqual(without, with);
    };
    var columns: u64 = 0;
    cases.longestColumns(true, texts[6..8], &columns);
    try std.testing.expectEqual(2, columns);
}

test "rowsTrimmed, rowsUpper" {
    const texts = [_][]const u8{
        "",       " ",                                "north,17", "  south\t",   "\t \t",                            "a b",
        "MiXed1", "0123456789abcdefghijklmnopqrstuv", "{`az@[",   "caf\xc3\xa9", " 123456789abcdefghijklmnopqrstu ",
    };
    var rows: [texts.len]cases.Row = undefined;
    for (&rows, texts) |*row, text| row.* = try cases.Row.from(text);
    for ([_][]const cases.Row{ &.{}, rows[0..4], &rows }) |some| inline for (.{ cases.rowsTrimmed, cases.rowsUpper }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, some, &with);
        case(false, some, &without);
        try std.testing.expectEqual(without, with);
    };
    var upper: u64 = 0;
    cases.rowsUpper(true, rows[5..6], &upper);
    try std.testing.expectEqual('A' + ' ' + 'B', upper);
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

test "mathChanged, mathReduced" {
    for (inputs) |items| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.mathChanged(true, items, &with);
        cases.mathChanged(false, items, &without);
        try std.testing.expectEqual(without, with);

        const Reduced = struct { count: usize = 99, low: u32 = 99, high: u32 = 99, product: u64 = 99, sum: u64 = 99 };
        var reduced: Reduced = .{};
        var by_hand: Reduced = .{ .count = 98 };
        cases.mathReduced(true, items, &reduced.count, &reduced.low, &reduced.high, &reduced.product, &reduced.sum);
        cases.mathReduced(false, items, &by_hand.count, &by_hand.low, &by_hand.high, &by_hand.product, &by_hand.sum);
        try std.testing.expectEqual(by_hand, reduced);
    }
}

test "mathSigned, mathDistance" {
    const signed = [_][]const i32{
        &.{},
        &.{-7},
        &.{ -20, -3, -1, 0, 1, 2, 3, 100, -100, std.math.maxInt(i32), std.math.minInt(i32) },
    };
    for (signed) |items| {
        var with: i64 = 99;
        var without: i64 = 98;
        cases.mathSigned(true, items, &with);
        cases.mathSigned(false, items, &without);
        try std.testing.expectEqual(without, with);

        var far: u64 = 99;
        var far_by_hand: u64 = 98;
        cases.mathDistance(true, items, &far);
        cases.mathDistance(false, items, &far_by_hand);
        try std.testing.expectEqual(far_by_hand, far);
    }
}

test "mathFloats" {
    const floats = [_][]const f64{ &.{}, &.{0.5}, &.{ -3, 0, 1.25, 7.5, 1e3, -1e-3 } };
    for (floats) |items| {
        var with: f64 = 99;
        var without: f64 = 98;
        cases.mathFloats(true, items, &with);
        cases.mathFloats(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "mathPlaced" {
    const rows = [_][4]u32{ .{ 1, 6, 7, 2 }, .{ 0, 0, 0, 0 }, .{ 100, 5, 6, 1000 } };
    for ([_][]const [4]u32{ &.{}, rows[0..1], &rows }) |some| {
        var with: u64 = 99;
        var without: u64 = 98;
        cases.mathPlaced(true, some, &with);
        cases.mathPlaced(false, some, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "mathChecked" {
    // The last input holds a value whose square does not fit: both variants
    // fail there and leave the result as it was.
    for (inputs) |items| {
        var with: u32 = 99;
        var without: u32 = 99;
        const passed = cases.mathChecked(false, items, &without);
        try std.testing.expectEqual(passed, cases.mathChecked(true, items, &with));
        try std.testing.expectEqual(without, with);
    }
    var untouched: u32 = 99;
    try std.testing.expect(!cases.mathChecked(true, inputs[3], &untouched));
    try std.testing.expectEqual(@as(u32, 99), untouched);
    try std.testing.expect(cases.mathChecked(true, inputs[2], &untouched));
}

test "mathMeasured" {
    for (inputs) |items| {
        var with: cases.Measured = .{ .count = 99 };
        var without: cases.Measured = .{ .count = 98 };
        cases.mathMeasured(true, items, &with);
        cases.mathMeasured(false, items, &without);
        try std.testing.expectEqual(without, with);
    }
}

test "collections: sortedSum, distinctSum, groupedSum" {
    // The third input has one item, one value and two groups too many, and
    // both variants fail there and leave the result as it was.
    inline for (.{ cases.sortedSum, cases.distinctSum, cases.groupedSum }) |case| {
        for (inputs, 0..) |items, i| {
            var with: u64 = 99;
            var without: u64 = 99;
            const passed = case(false, items, &without);
            try std.testing.expectEqual(i != 2, passed);
            try std.testing.expectEqual(passed, case(true, items, &with));
            try std.testing.expectEqual(without, with);
            if (!passed) try std.testing.expectEqual(@as(u64, 99), with);
        }
    }
}

test "collections: topSum, lastSum" {
    for (inputs) |items| inline for (.{ cases.topSum, cases.lastSum }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, items, &with);
        case(false, items, &without);
        try std.testing.expectEqual(without, with);
    };
}

test "checksummed, digested" {
    const texts = comptime textsOf(&.{
        "",                                                                       "a",    "bc",
        "a piece that is longer than one block of the hasher, which is 64 bytes", "\x00", "123456789",
    });
    for ([_][]const cases.Text{ &.{}, texts[0..1], texts[0..3], &texts }) |some| {
        var with: u32 = 99;
        var without: u32 = 98;
        cases.checksummed(true, some, &with);
        cases.checksummed(false, some, &without);
        try std.testing.expectEqual(without, with);

        var digest: [32]u8 = @splat(1);
        var by_hand: [32]u8 = @splat(2);
        cases.digested(true, some, &digest);
        cases.digested(false, some, &by_hand);
        try std.testing.expectEqual(by_hand, digest);
    }
}

test "hexed, base64ed" {
    const words = [_]cases.Word{
        .{ .bytes = .{ 0, 0, 0, 0 } },
        .{ .bytes = .{ 0xff, 0xfe, 0x10, 0x0f } },
        .{ .bytes = "zrx!".* },
        .{ .bytes = .{ 0xfb, 0xff, 0xbf, 0x3e } },
    };
    for ([_][]const cases.Word{ &.{}, words[0..1], &words }) |some| inline for (.{ cases.hexed, cases.base64ed }) |case| {
        var with: u64 = 99;
        var without: u64 = 98;
        case(true, some, &with);
        case(false, some, &without);
        try std.testing.expectEqual(without, with);
    };
}
