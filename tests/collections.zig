//! `zrx.ext.collections`: operators that keep items in room of a size
//! written with them. No test here is given an allocator: there is none to
//! ask for.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const fold = zrx.fold;
const forEach = zrx.forEach;
const field = zrx.field;
const recover = zrx.recover;
const drain = zrx.drain;

const collections = zrx.ext.collections;
const itself = collections.itself;
const distinct = collections.distinct;
const foldBy = collections.foldBy;
const sorted = collections.sorted;
const top = collections.top;
const takeLast = collections.takeLast;
const ascending = collections.ascending;
const descending = collections.descending;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

/// A source that counts what it pushed, to show where a pipe stopped it.
const Counting = struct {
    items: []const u32,
    pushed: *usize,

    pub const zrx_source = {};
    pub const Item = u32;

    pub fn run(self: *const Counting, _: anytype, down: anytype) !void {
        for (self.items) |item| {
            self.pushed.* += 1;
            if (try down.push(item) == .done) return;
        }
    }
};

/// Words pushed as slices of two buffers used in turn, each overwritten by
/// the word after the next: what an operator keeps of such an item is gone
/// two pushes later unless it is a value.
const Words = struct {
    words: []const []const u8,

    pub const zrx_source = {};
    pub const Item = []const u8;

    pub fn run(self: *const Words, _: anytype, down: anytype) !void {
        var buffers: [2][16]u8 = undefined;
        for (self.words, 0..) |word, i| {
            const buffer = &buffers[i % 2];
            @memset(buffer, '#');
            @memcpy(buffer[0..word.len], word);
            if (try down.push(buffer[0..word.len]) == .done) return;
        }
    }
};

fn failAt(comptime bad: u32) fn (u32) error{Bad}!u32 {
    return struct {
        fn check(value: u32) error{Bad}!u32 {
            if (value == bad) return error.Bad;
            return value;
        }
    }.check;
}

fn lastDigit(value: u32) u32 {
    return value % 10;
}

fn count(total: u32, _: anytype) u32 {
    return total + 1;
}

fn add(total: u32, value: u32) u32 {
    return total + value;
}

/// The items an error path was given.
const Rejected = struct { items: Numbers = .{} };

fn rejectBad(rejected: *Rejected, failed: zrx.Failed(error{Bad}, u32)) void {
    rejected.items.add(failed.item);
}

fn rejectItem(rejected: *Rejected, failed: zrx.Failed(error{TooManyItems}, u32)) void {
    rejected.items.add(failed.item);
}

fn rejectKey(rejected: *Rejected, failed: zrx.Failed(error{TooManyKeys}, u32)) void {
    rejected.items.add(failed.item);
}

const Count = zrx.Tagged(u32, u32);
const Counts = support.Recorder(Count);

fn recordCount(counts: *Counts, pair: Count) void {
    counts.add(pair);
}

fn expectCounts(counts: *const Counts, expected: []const Count) !void {
    try std.testing.expectEqual(expected.len, counts.len);
    for (expected, counts.slice()) |want, got| {
        try std.testing.expectEqual(want.source, got.source);
        try std.testing.expectEqual(want.item, got.item);
    }
}

// --- room -----------------------------------------------------------------------

test "sorted, distinct and foldBy fail the item that does not fit, with an error that has a name" {
    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    const source: Counting = .{ .items = &items, .pushed = &pushed };

    // It is the one thing these runs can fail with, and it stops the source
    // at the item that brought it.
    var left = support.runLeft(program(source, .{ sorted(4, ascending(itself)), drain() }), .{});
    try std.testing.expectEqualStrings("TooManyItems ", left.names());
    try std.testing.expectEqual(error.TooManyItems, left.err.?);
    try std.testing.expectEqual(@as(usize, 5), pushed);

    pushed = 0;
    left = support.runLeft(program(source, .{ distinct(2, itself), drain() }), .{});
    try std.testing.expectEqualStrings("TooManyKeys ", left.names());
    try std.testing.expectEqual(error.TooManyKeys, left.err.?);
    try std.testing.expectEqual(@as(usize, 3), pushed);

    pushed = 0;
    left = support.runLeft(program(source, .{ foldBy(3, itself, @as(u32, 0), count), drain() }), .{});
    try std.testing.expectEqualStrings("TooManyKeys ", left.names());
    try std.testing.expectEqual(error.TooManyKeys, left.err.?);
    try std.testing.expectEqual(@as(usize, 4), pushed);
}

test "an error path before the operator takes the item that did not fit, and the rest goes on" {
    var seen: Numbers = .{};
    var rejected: Rejected = .{};
    try support.run(program(fromSlice(&[_]u32{ 31, 4, 15, 9, 26, 5 }), .{
        recover(error{TooManyItems}, .{forEach(rejectItem)}),
        sorted(4, ascending(itself)),
        forEach(record),
    }), .{ &seen, &rejected });
    try seen.expect(&.{ 4, 9, 15, 31 });
    try rejected.items.expect(&.{ 26, 5 });

    // A key that was seen is dropped as before, also when no other fits.
    var unique: Numbers = .{};
    var late: Rejected = .{};
    try support.run(program(fromSlice(&[_]u32{ 1, 2, 1, 3, 4, 2, 5, 3 }), .{
        recover(error{TooManyKeys}, .{forEach(rejectKey)}),
        distinct(3, itself),
        forEach(record),
    }), .{ &unique, &late });
    try unique.expect(&.{ 1, 2, 3 });
    try late.items.expect(&.{ 4, 5 });

    // A key that has a state is folded into as before.
    var counts: Counts = .{};
    var keyless: Rejected = .{};
    try support.run(program(fromSlice(&[_]u32{ 13, 21, 33, 42, 51, 60, 3 }), .{
        recover(error{TooManyKeys}, .{forEach(rejectKey)}),
        foldBy(2, lastDigit, @as(u32, 0), count),
        forEach(recordCount),
    }), .{ &counts, &keyless });
    try expectCounts(&counts, &.{
        .{ .source = 3, .item = 3 },
        .{ .source = 1, .item = 2 },
    });
    try keyless.items.expect(&.{ 42, 60 });
}

test "exactly as many as there is room for fit" {
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(6, descending(itself)), forEach(record) }), .{&seen});
    try seen.expect(&.{ 31, 26, 15, 9, 5, 4 });

    var unique: Numbers = .{};
    try support.run(program(fromSlice(&(items ++ items)), .{ distinct(6, itself), forEach(record) }), .{&unique});
    try unique.expect(&items);

    var keys: Numbers = .{};
    try support.run(program(fromSlice(&(items ++ items)), .{ foldBy(6, itself, @as(u32, 0), count), map(field(.source)), forEach(record) }), .{&keys});
    try keys.expect(&items);
}

/// Checks what comes against what should, where there is more of it than a
/// recorder holds.
const Expected = struct {
    items: []const u32,
    at: usize = 0,
    wrong: bool = false,

    fn next(expected: *Expected, item: u32) void {
        if (expected.at >= expected.items.len or expected.items[expected.at] != item) expected.wrong = true;
        expected.at += 1;
    }
};

fn addWrapping(total: u32, value: u32) u32 {
    return total +% value;
}

test "a table finds every key again, at every size and when it is full" {
    inline for (.{ 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 255, 256, 257, 600 }) |room| {
        // Every key three times, in an order that is not that of the keys,
        // and keys that are far apart.
        var items: [room * 3]u32 = undefined;
        var first: [room]u32 = undefined;
        for (&items, 0..) |*item, i| item.* = @as(u32, @intCast((i * 7919) % room)) * 2_654_435;
        for (&first, items[0..room]) |*to, item| to.* = item;

        var unique: Expected = .{ .items = &first };
        try support.run(program(fromSlice(&items), .{ distinct(room, itself), forEach(Expected.next) }), .{&unique});
        try std.testing.expectEqual(@as(usize, room), unique.at);
        try std.testing.expect(!unique.wrong);

        // A key that is not there is looked for in a table that is full,
        // and the look ends: at an empty place, of which there always is one.
        const stranger = [_]u32{7};
        const full = support.run(program(fromSlice(&(items ++ stranger)), .{ distinct(room, itself), drain() }), .{});
        try std.testing.expectError(error.TooManyKeys, full);

        var states: [room]u32 = undefined;
        for (&states, first) |*state, key| state.* = key *% 3;
        var sums: Expected = .{ .items = &states };
        try support.run(program(fromSlice(&items), .{ foldBy(room, itself, @as(u32, 0), addWrapping), map(field(.item)), forEach(Expected.next) }), .{&sums});
        try std.testing.expectEqual(@as(usize, room), sums.at);
        try std.testing.expect(!sums.wrong);
    }
}

// --- distinct -------------------------------------------------------------------

test "distinct passes an item the first time its key is seen" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 3, 1, 3, 2, 1, 3, 4 }), .{ distinct(8, itself), forEach(record) }), .{&seen});
    try seen.expect(&.{ 3, 1, 2, 4 });

    var by_key: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 13, 21, 33, 42, 51, 60 }), .{ distinct(8, lastDigit), forEach(record) }), .{&by_key});
    try by_key.expect(&.{ 13, 21, 42, 60 });
}

const Reading = struct { sensor: u8, room: enum { hall, lab }, value: u32 };
const Place = struct { sensor: u8, lab: bool };

fn placeOf(reading: Reading) Place {
    return .{ .sensor = reading.sensor, .lab = reading.room == .lab };
}

fn valueOf(reading: Reading) u32 {
    return reading.value;
}

test "distinct tells keys apart by all of their parts" {
    const readings = [_]Reading{
        .{ .sensor = 1, .room = .hall, .value = 10 },
        .{ .sensor = 1, .room = .lab, .value = 11 },
        .{ .sensor = 1, .room = .hall, .value = 12 },
        .{ .sensor = 2, .room = .lab, .value = 13 },
        .{ .sensor = 1, .room = .lab, .value = 14 },
    };
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&readings), .{ distinct(8, placeOf), map(valueOf), forEach(record) }), .{&seen});
    try seen.expect(&.{ 10, 11, 13 });

    var rooms: Numbers = .{};
    try support.run(program(fromSlice(&readings), .{ distinct(8, field(.room)), map(valueOf), forEach(record) }), .{&rooms});
    try rooms.expect(&.{ 10, 11 });
}

const Text = support.Recorder(u8);

fn spellLine(text: *Text, line: zrx.Line(8)) void {
    for (line.text()) |byte| text.add(byte);
    text.add(' ');
}

/// What the unused bytes of the next line are filled with.
const Filler = struct { next: u8 = 0 };

/// A line of `word` whose unused bytes are different every time: what lies
/// behind the text of a line is no part of a key.
fn lineOf(filler: *Filler, word: []const u8) zrx.Line(8) {
    var line: zrx.Line(8) = .{ .bytes = @splat(filler.next), .len = word.len };
    filler.next +%= 1;
    @memcpy(line.bytes[0..word.len], word);
    return line;
}

test "distinct keeps a line as a key and reads it by its text" {
    // The buffer a word came from holds another word two pushes later; the
    // line is a value and is still what it was.
    const words: Words = .{ .words = &.{ "pear", "fig", "plum", "pear", "fig", "pea" } };
    var text: Text = .{};
    var filler: Filler = .{};
    try support.run(program(words, .{ map(lineOf), distinct(4, itself), forEach(spellLine) }), .{ &text, &filler });
    try text.expect("pear fig plum pea ");
}

test "distinct: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ distinct(8, itself), forEach(record) }), .{&seen});
    try seen.expect(&.{});

    // Done after two: the source is stopped where the second new key came.
    var pushed: usize = 0;
    const items = [_]u32{ 1, 1, 2, 2, 3, 3 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ distinct(8, itself), take(2), forEach(record) }), .{&seen});
    try seen.expect(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ distinct(8, itself), map(failAt(3)), forEach(record) }), .{&failed});
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 1, 2 });
}

const Marked = struct { id: u32, bad: bool };

fn unmarked(item: Marked) error{Bad}!u32 {
    if (item.bad) return error.Bad;
    return item.id;
}

fn rejectMarked(rejected: *Rejected, failed: zrx.Failed(error{Bad}, Marked)) void {
    rejected.items.add(failed.item.id);
}

test "distinct: a key counts as seen whatever became of its item" {
    // The first 7 fails further down and is taken by the error path; the
    // second one is its duplicate all the same.
    const items = [_]Marked{
        .{ .id = 7, .bad = true },
        .{ .id = 7, .bad = false },
        .{ .id = 8, .bad = false },
    };
    var seen: Numbers = .{};
    var rejected: Rejected = .{};
    try support.run(program(fromSlice(&items), .{
        recover(error{Bad}, .{forEach(rejectMarked)}),
        distinct(8, field(.id)),
        map(unmarked),
        forEach(record),
    }), .{ &seen, &rejected });
    try seen.expect(&.{8});
    try rejected.items.expect(&.{7});
}

// --- foldBy ---------------------------------------------------------------------

test "foldBy folds every key's items and emits the keys in the order they were first seen" {
    const items = [_]u32{ 13, 21, 33, 42, 51, 60, 3 };
    var counts: Counts = .{};
    try support.run(program(fromSlice(&items), .{ foldBy(8, lastDigit, @as(u32, 0), count), forEach(recordCount) }), .{&counts});
    try expectCounts(&counts, &.{
        .{ .source = 3, .item = 3 },
        .{ .source = 1, .item = 2 },
        .{ .source = 2, .item = 1 },
        .{ .source = 0, .item = 1 },
    });

    var sums: Counts = .{};
    try support.run(program(fromSlice(&items), .{ foldBy(8, lastDigit, @as(u32, 100), add), forEach(recordCount) }), .{&sums});
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 149 },
        .{ .source = 1, .item = 172 },
        .{ .source = 2, .item = 142 },
        .{ .source = 0, .item = 160 },
    });
}

const Scale = struct { by: u32 };

fn scaledDigit(scale: Scale, value: u32) u32 {
    return (value % 10) * scale.by;
}

fn addScaled(scale: Scale, total: u32, value: u32) u32 {
    return total + value * scale.by;
}

test "foldBy: the key and the reducer take dependencies" {
    var sums: Counts = .{};
    try support.run(program(fromSlice(&[_]u32{ 11, 12, 21 }), .{ foldBy(8, scaledDigit, @as(u32, 0), addScaled), forEach(recordCount) }), .{ &sums, Scale{ .by = 3 } });
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 96 },
        .{ .source = 6, .item = 36 },
    });
}

fn spellCount(text: *Text, pair: zrx.Tagged(zrx.Line(8), u32)) void {
    for (pair.source.text()) |byte| text.add(byte);
    text.add('0' + @as(u8, @intCast(pair.item)));
    text.add(' ');
}

test "foldBy hands on a line that was its key" {
    const words: Words = .{ .words = &.{ "pear", "fig", "pear", "plum", "fig", "pear" } };
    var text: Text = .{};
    var filler: Filler = .{};
    try support.run(program(words, .{ map(lineOf), foldBy(4, itself, @as(u32, 0), count), forEach(spellCount) }), .{ &text, &filler });
    try text.expect("pear3 fig2 plum1 ");
}

fn failCount(pair: Count) error{Bad}!Count {
    if (pair.source == 1) return error.Bad;
    return pair;
}

test "foldBy: an empty stream, a pipe that is done, a pipe that fails" {
    var counts: Counts = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ foldBy(8, lastDigit, @as(u32, 0), count), forEach(recordCount) }), .{&counts});
    try expectCounts(&counts, &.{});

    // Nothing is emitted before the end, so the source runs out; the pipe
    // after it is done with the first key.
    var pushed: usize = 0;
    const items = [_]u32{ 13, 21, 33, 42 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ foldBy(8, lastDigit, @as(u32, 0), count), take(1), forEach(recordCount) }), .{&counts});
    try expectCounts(&counts, &.{.{ .source = 3, .item = 2 }});
    try std.testing.expectEqual(@as(usize, 4), pushed);

    var failed: Counts = .{};
    const result = support.run(program(fromSlice(&items), .{ foldBy(8, lastDigit, @as(u32, 0), count), map(failCount), forEach(recordCount) }), .{&failed});
    try std.testing.expectError(error.Bad, result);
    try expectCounts(&failed, &.{.{ .source = 3, .item = 2 }});
}

fn addSmall(total: u32, value: u32) error{Bad}!u32 {
    if (value >= 100) return error.Bad;
    return total + value;
}

test "foldBy: an item whose reducer fails leaves no trace" {
    // 105 would be the first of key 5, 203 comes to a key that has a state.
    const items = [_]u32{ 13, 105, 203, 23, 44 };
    var sums: Counts = .{};
    var rejected: Rejected = .{};
    try support.run(program(fromSlice(&items), .{
        recover(error{Bad}, .{forEach(rejectBad)}),
        foldBy(8, lastDigit, @as(u32, 0), addSmall),
        forEach(recordCount),
    }), .{ &sums, &rejected });
    try rejected.items.expect(&.{ 105, 203 });
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 36 },
        .{ .source = 4, .item = 44 },
    });
}

test "foldBy: an item that does not fit is not given to the reducer" {
    // 105 would fail in the reducer, and an error path is there to take
    // that. It brings a third key where there is room for two.
    var sums: Counts = .{};
    var rejected: Rejected = .{};
    const result = support.run(program(fromSlice(&[_]u32{ 13, 24, 105 }), .{
        recover(error{Bad}, .{forEach(rejectBad)}),
        foldBy(2, lastDigit, @as(u32, 0), addSmall),
        forEach(recordCount),
    }), .{ &sums, &rejected });
    try std.testing.expectError(error.TooManyKeys, result);
    try rejected.items.expect(&.{});
}

test "foldBy: a key that is rejected again and again takes no room" {
    // Finding 1 of the review of PR 71: with room for two keys, key 5 is
    // rejected six times, and two keys come that have to fit.
    const items = [_]u32{ 105, 105, 205, 105, 305, 13, 105, 24, 23 };
    var sums: Counts = .{};
    var rejected: Rejected = .{};
    try support.run(program(fromSlice(&items), .{
        recover(error{Bad}, .{forEach(rejectBad)}),
        foldBy(2, lastDigit, @as(u32, 0), addSmall),
        forEach(recordCount),
    }), .{ &sums, &rejected });
    try rejected.items.expect(&.{ 105, 105, 205, 105, 305, 105 });
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 36 },
        .{ .source = 4, .item = 24 },
    });
}

fn digitOfSmall(value: u32) error{Bad}!u32 {
    if (value >= 100) return error.Bad;
    return value % 10;
}

test "an item whose key fails takes no room either" {
    const items = [_]u32{ 105, 105, 205, 13, 105, 24, 23 };
    var seen: Numbers = .{};
    var rejected: Rejected = .{};
    try support.run(program(fromSlice(&items), .{
        recover(error{Bad}, .{forEach(rejectBad)}),
        distinct(2, digitOfSmall),
        forEach(record),
    }), .{ &seen, &rejected });
    try seen.expect(&.{ 13, 24 });
    try rejected.items.expect(&.{ 105, 105, 205, 105 });
}

// --- sorted ---------------------------------------------------------------------

test "sorted pushes the stream in order when it ends" {
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    var up: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, ascending(itself)), forEach(record) }), .{&up});
    try up.expect(&.{ 4, 5, 9, 15, 26, 31 });

    var down: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, descending(itself)), forEach(record) }), .{&down});
    try down.expect(&.{ 31, 26, 15, 9, 5, 4 });
}

test "sorted: items the order does not tell apart keep the order they came in" {
    const items = [_]u32{ 31, 42, 11, 22, 41, 12, 21 };
    var up: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, ascending(lastDigit)), forEach(record) }), .{&up});
    try up.expect(&.{ 31, 11, 41, 21, 42, 22, 12 });

    var down: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, descending(lastDigit)), forEach(record) }), .{&down});
    try down.expect(&.{ 42, 22, 12, 31, 11, 41, 21 });
}

const Near = struct { to: u32 };

fn nearer(near: Near, a: u32, b: u32) bool {
    return @max(a, near.to) - @min(a, near.to) < @max(b, near.to) - @min(b, near.to);
}

test "sorted takes an order of the caller's own, with its dependencies" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 1, 20, 9, 14, 11 }), .{ sorted(8, nearer), forEach(record) }), .{ &seen, Near{ .to = 10 } });
    try seen.expect(&.{ 9, 11, 14, 1, 20 });
}

const Level = enum(u8) { debug = 1, warn = 5, info = 3 };
const Event = struct { level: Level, heat: f32, id: u32 };

fn idOf(event: Event) u32 {
    return event.id;
}

fn spell(text: *Text, word: []const u8) void {
    for (word) |byte| text.add(byte);
    text.add(' ');
}

test "sorted orders by text, by the value of an enum tag and by a float" {
    const words: Words = .{ .words = &.{ "pear", "fig", "plum", "pea", "figs" } };
    var text: Text = .{};
    var filler: Filler = .{};
    try support.run(program(words, .{ map(lineOf), sorted(8, ascending(itself)), forEach(spellLine) }), .{ &text, &filler });
    try text.expect("fig figs pea pear plum ");

    // An order may read a text that the item only points at: it is asked
    // while the items are there.
    const names = [_][]const u8{ "pear", "fig", "plum" };
    var pointed: Text = .{};
    try support.run(program(fromSlice(&names), .{ sorted(8, descending(itself)), forEach(spell) }), .{&pointed});
    try pointed.expect("plum pear fig ");

    const events = [_]Event{
        .{ .level = .warn, .heat = 0.5, .id = 1 },
        .{ .level = .debug, .heat = -2.0, .id = 2 },
        .{ .level = .info, .heat = 9.25, .id = 3 },
    };
    var by_level: Numbers = .{};
    try support.run(program(fromSlice(&events), .{ sorted(8, ascending(field(.level))), map(idOf), forEach(record) }), .{&by_level});
    try by_level.expect(&.{ 2, 3, 1 });

    var by_heat: Numbers = .{};
    try support.run(program(fromSlice(&events), .{ sorted(8, descending(field(.heat))), map(idOf), forEach(record) }), .{&by_heat});
    try by_heat.expect(&.{ 3, 1, 2 });
}

test "sorted: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ sorted(8, ascending(itself)), forEach(record) }), .{&seen});
    try seen.expect(&.{});

    // It has to see everything before it can push anything.
    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ sorted(8, ascending(itself)), take(2), forEach(record) }), .{&seen});
    try seen.expect(&.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    // Stopped before it: it sorts what it was given.
    var first: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ take(3), sorted(8, ascending(itself)), forEach(record) }), .{&first});
    try first.expect(&.{ 4, 15, 31 });

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ sorted(8, ascending(itself)), map(failAt(15)), forEach(record) }), .{&failed});
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 4, 5, 9 });
}

// --- a float that is not a number -------------------------------------------------

const nan = std.math.nan(f32);

fn bitsOf(value: f32) u32 {
    return @bitCast(value);
}

fn bits(comptime values: anytype) [values.len]u32 {
    var out: [values.len]u32 = undefined;
    inline for (&out, values) |*to, value| to.* = @bitCast(@as(f32, value));
    return out;
}

test "a NaN comes after every number, smallest first and largest first" {
    const items = [_]f32{ 3, nan, 1, -nan, 2 };
    var up: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, ascending(itself)), map(bitsOf), forEach(record) }), .{&up});
    // The two that are not numbers keep the order they came in.
    try up.expect(&bits(.{ 1, 2, 3, nan, -nan }));

    var down: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(8, descending(itself)), map(bitsOf), forEach(record) }), .{&down});
    try down.expect(&bits(.{ 3, 2, 1, nan, -nan }));
}

test "sorted then take and top agree on a stream with a NaN in it" {
    // Finding 2 of the review of PR 71: for these three, `sorted` and
    // `take(1)` emitted 3 where `top(1)` emitted 1.
    const items = [_]f32{ 3, nan, 1 };
    inline for (.{ ascending(itself), descending(itself) }, .{ 1, 3 }) |order, wanted| {
        var by_sorted: Numbers = .{};
        try support.run(program(fromSlice(&items), .{ sorted(8, order), take(1), map(bitsOf), forEach(record) }), .{&by_sorted});
        try by_sorted.expect(&bits(.{wanted}));

        var by_top: Numbers = .{};
        try support.run(program(fromSlice(&items), .{ top(1, order), map(bitsOf), forEach(record) }), .{&by_top});
        try by_top.expect(&bits(.{wanted}));
    }
}

// --- top ------------------------------------------------------------------------

test "top keeps the first items of an order and pushes them in that order" {
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    var largest: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ top(3, descending(itself)), forEach(record) }), .{&largest});
    try largest.expect(&.{ 31, 26, 15 });

    var smallest: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ top(2, ascending(itself)), forEach(record) }), .{&smallest});
    try smallest.expect(&.{ 4, 5 });
}

test "top emits what sorted and take emit, for every count and with ties" {
    var random: std.Random.DefaultPrng = .init(0x7a7278);
    var items: [40]u32 = undefined;
    for ([_]usize{ 0, 1, 2, 7, 40 }) |len| {
        // Few distinct keys, so that most items tie with others.
        for (items[0..len]) |*item| item.* = random.random().uintLessThan(u32, 90);
        inline for (.{ 1, 2, 3, 5, 39, 40, 41, 100 }) |limit| {
            inline for (.{ ascending(lastDigit), descending(lastDigit), ascending(itself) }) |order| {
                var kept: Numbers = .{};
                try support.run(program(fromSlice(items[0..len]), .{ top(limit, order), forEach(record) }), .{&kept});
                var wanted: Numbers = .{};
                try support.run(program(fromSlice(items[0..len]), .{ sorted(40, order), take(limit), forEach(record) }), .{&wanted});
                try kept.expect(wanted.slice());
            }
        }
    }
}

/// A float out of a number: a few values, so that many tie, and every
/// fifth is not a number.
fn heatOf(value: u32) f32 {
    return if (value % 5 == 0) nan else @floatFromInt(value % 7);
}

/// The item with its place in the stream, so that two with one heat can be
/// told apart in what comes out.
const Heated = struct { heat: f32, id: u32 };

fn heated(next: *u32, value: u32) Heated {
    defer next.* += 1;
    return .{ .heat = heatOf(value), .id = next.* };
}

test "top emits what sorted and take emit when some keys are not numbers" {
    var random: std.Random.DefaultPrng = .init(0x6e616e);
    var items: [40]u32 = undefined;
    for (&items) |*item| item.* = random.random().uintLessThan(u32, 90);
    inline for (.{ 1, 2, 5, 20, 39, 40 }) |limit| {
        inline for (.{ ascending(field(.heat)), descending(field(.heat)) }) |order| {
            var kept: Numbers = .{};
            var next: u32 = 0;
            try support.run(program(fromSlice(&items), .{ map(heated), top(limit, order), map(field(.id)), forEach(record) }), .{ &kept, &next });
            var wanted: Numbers = .{};
            next = 0;
            try support.run(program(fromSlice(&items), .{ map(heated), sorted(40, order), take(limit), map(field(.id)), forEach(record) }), .{ &wanted, &next });
            try kept.expect(wanted.slice());
        }
    }
}

test "top: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ top(3, ascending(itself)), forEach(record) }), .{&seen});
    try seen.expect(&.{});

    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ top(4, ascending(itself)), take(2), forEach(record) }), .{&seen});
    try seen.expect(&.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ top(4, ascending(itself)), map(failAt(9)), forEach(record) }), .{&failed});
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 4, 5 });
}

// --- takeLast -------------------------------------------------------------------

test "takeLast pushes the last items in the order they came" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 10), .{ takeLast(3), forEach(record) }), .{&seen});
    try seen.expect(&.{ 7, 8, 9 });

    // Exactly as many, fewer than asked for, and only one.
    var all: Numbers = .{};
    try support.run(program(range(u32, 0, 4), .{ takeLast(4), forEach(record) }), .{&all});
    try support.run(program(range(u32, 0, 2), .{ takeLast(4), forEach(record) }), .{&all});
    try support.run(program(range(u32, 0, 9), .{ takeLast(1), forEach(record) }), .{&all});
    try all.expect(&.{ 0, 1, 2, 3, 0, 1, 8 });
}

test "takeLast keeps the last items however many came before" {
    inline for (.{ 1, 2, 3, 8 }) |kept| {
        for (0..40) |len| {
            var seen: Numbers = .{};
            try support.run(program(range(u32, 0, @intCast(len)), .{ takeLast(kept), forEach(record) }), .{&seen});
            const from = len -| kept;
            try std.testing.expectEqual(len - from, seen.len);
            for (seen.slice(), from..) |got, want| try std.testing.expectEqual(@as(u32, @intCast(want)), got);
        }
    }
}

test "takeLast: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ takeLast(3), forEach(record) }), .{&seen});
    try seen.expect(&.{});

    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ takeLast(4), take(2), forEach(record) }), .{&seen});
    try seen.expect(&.{ 15, 9 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ takeLast(4), map(failAt(26)), forEach(record) }), .{&failed});
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 15, 9 });
}

// --- with the rest of the library -------------------------------------------------

fn isOdd(value: u32) bool {
    return value % 2 == 1;
}

test "the operators compose with each other and with the built-in ones" {
    // The three last digits that occur most often, by how often.
    const items = [_]u32{ 13, 21, 33, 42, 51, 60, 3, 71, 81, 12 };
    var counts: Counts = .{};
    try support.run(program(fromSlice(&items), .{
        foldBy(16, lastDigit, @as(u32, 0), count),
        top(3, descending(field(.item))),
        forEach(recordCount),
    }), .{&counts});
    try expectCounts(&counts, &.{
        .{ .source = 1, .item = 4 },
        .{ .source = 3, .item = 3 },
        .{ .source = 2, .item = 2 },
    });

    var seen: Numbers = .{};
    try support.run(program(fromSlice(&items), .{
        filter(isOdd),
        distinct(16, lastDigit),
        sorted(16, descending(itself)),
        takeLast(2),
        forEach(record),
    }), .{&seen});
    try seen.expect(&.{ 21, 13 });
}

fn firstDigits(limit: u32) @TypeOf(range(u32, 0, 0)) {
    return range(u32, 0, limit);
}

fn mirrored(value: u32) u32 {
    return if (value % 2 == 0) value else 100 - value;
}

test "inside each, a sub-pipe keeps what it holds for one item" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 3, 4 }), .{
        zrx.each(firstDigits, .{ map(mirrored), sorted(8, ascending(itself)) }),
        map(field(.item)),
        forEach(record),
    }), .{&seen});
    try seen.expect(&.{ 0, 2, 99, 0, 2, 97, 99 });

    // Each item finds the room empty: what the one before it saw is seen
    // again, and what it kept is not there.
    inline for (.{
        pipe(.{distinct(4, itself)}),
        pipe(.{ foldBy(4, itself, @as(u32, 0), add), map(field(.source)) }),
        pipe(.{takeLast(4)}),
        pipe(.{top(4, ascending(itself))}),
    }) |held| {
        var again: Numbers = .{};
        try support.run(program(fromSlice(&[_]u32{ 3, 4, 4 }), .{
            zrx.each(firstDigits, held),
            map(field(.item)),
            forEach(record),
        }), .{&again});
        try again.expect(&.{ 0, 1, 2, 0, 1, 2, 3, 0, 1, 2, 3 });
    }
}

test "in the sub-pipes of a branch each operator has a state of its own" {
    var low: Numbers = .{};
    var high: support.Recorder(u64) = .{};
    try support.run(program(fromSlice(&[_]u32{ 31, 4, 15, 9, 26, 5 }), .{zrx.branch(.{
        .{ top(2, ascending(itself)), forEach(record) },
        .{ top(2, descending(itself)), map(widen), forEach(support.record(u64)) },
    })}), .{ &low, &high });
    try low.expect(&.{ 4, 5 });
    try high.expect(&.{ 31, 26 });
}

fn widen(value: u32) u64 {
    return value;
}

test "behind a queue the operators run on its task" {
    const io = std.testing.io;
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 200), .{
        distinct(16, lastDigit),
        zrx.queue(4),
        sorted(16, descending(itself)),
        takeLast(3),
        forEach(record),
    }), .{ io, &seen });
    try seen.expect(&.{ 2, 1, 0 });

    var failed: Numbers = .{};
    const result = support.run(program(range(u32, 0, 200), .{
        zrx.queue(4),
        distinct(16, lastDigit),
        map(failAt(7)),
        sorted(16, ascending(itself)),
        forEach(record),
    }), .{ io, &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{});
}

fn keep(total: *u32, value: u32) void {
    total.* = value;
}

fn one(_: u32) u32 {
    return 1;
}

test "every worker of concurrent has room of its own" {
    // Which worker is given which item is not decided, so what is checked
    // holds however they share: every item is counted once, in one of the
    // tables, and every item is kept once, in one of the buffers.
    const io = std.testing.io;
    inline for (.{
        pipe(.{ foldBy(16, lastDigit, @as(u32, 0), count), map(field(.item)) }),
        pipe(.{ sorted(256, ascending(itself)), map(one) }),
    }) |held| {
        var total: u32 = 0;
        try support.run(program(range(u32, 0, 200), .{
            zrx.concurrent(3, held),
            fold(@as(u32, 0), add),
            forEach(keep),
        }), .{ io, &total });
        try std.testing.expectEqual(@as(u32, 200), total);
    }
}
