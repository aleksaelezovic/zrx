//! `zrx.ext.collections`: operators that keep items in a std container.
//!
//! Every test runs over `std.testing.allocator`, which fails a test that
//! leaves memory behind: the operators here are given their memory by a
//! binding, and a run that fails has to give it back as one that ends does.
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
const memory = collections.memory;
const itself = collections.itself;
const distinct = collections.distinct;
const foldBy = collections.foldBy;
const sorted = collections.sorted;
const top = collections.top;
const takeLast = collections.takeLast;
const ascending = collections.ascending;
const descending = collections.descending;

const gpa = std.testing.allocator;

const Numbers = support.Recorder(u32);
const record = support.record(u32);

/// A source that pushes `items` and then fails, unless a push was answered
/// `.done` first. `pushed` counts what it got to push.
const Failing = struct {
    items: []const u32,
    pushed: *usize,

    pub const zrx_source = {};
    pub const Item = u32;

    pub fn run(self: *const Failing, _: anytype, down: anytype) !void {
        for (self.items) |item| {
            self.pushed.* += 1;
            if (try down.push(item) == .done) return;
        }
        return error.SourceBroke;
    }
};

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
/// two pushes later unless copied, and the same word comes back in the
/// other buffer.
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

// --- memory ---------------------------------------------------------------------

test "memory gives everything back when the run is over, however it ended" {
    const items = [_]u32{ 5, 3, 5, 9, 3, 1, 7, 7, 2 };
    var pushed: usize = 0;
    const ending = fromSlice(&items);
    const breaking: Failing = .{ .items = &items, .pushed = &pushed };
    inline for (.{
        pipe(.{ distinct(itself), drain() }),
        pipe(.{ foldBy(lastDigit, @as(u32, 0), add), drain() }),
        pipe(.{ sorted(ascending(itself)), drain() }),
        pipe(.{ top(3, descending(itself)), drain() }),
        pipe(.{ takeLast(4), drain() }),
    }) |held| {
        // It ends, and its source fails: the stages are never told.
        var counted = std.testing.FailingAllocator.init(gpa, .{});
        try support.run(program(ending, held), .{ counted.allocator(), memory() });
        try std.testing.expect(counted.allocated_bytes != 0);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);

        counted = std.testing.FailingAllocator.init(gpa, .{});
        try std.testing.expectError(error.SourceBroke, support.run(program(breaking, held), .{ counted.allocator(), memory() }));
        try std.testing.expect(counted.allocated_bytes != 0);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}

test "running out of memory fails the run like a handler error, wherever it happens" {
    var numbers: [600]u32 = undefined;
    for (&numbers, 0..) |*number, i| number.* = @intCast((i * 7919) % 601);
    inline for (.{
        pipe(.{ distinct(itself), drain() }),
        pipe(.{ foldBy(itself, @as(u32, 0), count), drain() }),
        pipe(.{ sorted(ascending(itself)), drain() }),
        pipe(.{ top(500, descending(itself)), drain() }),
        pipe(.{ takeLast(500), drain() }),
    }) |held| {
        // Refuse the first allocation, then the second, and so on, until a
        // run is given all it asks for.
        var refused: usize = 0;
        while (true) : (refused += 1) {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = refused });
            const left = support.runLeft(program(fromSlice(&numbers), held), .{ failing.allocator(), memory() });
            const err = left.err orelse break;
            // It is the one thing these runs can fail with.
            try std.testing.expectEqualStrings("OutOfMemory ", left.names());
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expect(refused != 0);
    }
}

test "an arena of the caller's own takes the place of the binding" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var seen: Numbers = .{};
    const unique = program(fromSlice(&[_]u32{ 4, 4, 2, 4, 2 }), .{
        distinct(itself),
        forEach(record),
    }).provide(.{memory()});
    // The default is replaced and not acquired: no allocator is asked for.
    try support.run(unique, .{ collections.Memory{ .arena = &arena }, &seen });
    try seen.expect(&.{ 4, 2 });
    try std.testing.expect(arena.queryCapacity() != 0);
}

// --- distinct -------------------------------------------------------------------

test "distinct passes an item the first time its key is seen" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 3, 1, 3, 2, 1, 3, 4 }), .{ distinct(itself), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 3, 1, 2, 4 });

    var by_key: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 13, 21, 33, 42, 51, 60 }), .{ distinct(lastDigit), forEach(record) }), .{ gpa, memory(), &by_key });
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
    try support.run(program(fromSlice(&readings), .{ distinct(placeOf), map(valueOf), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 10, 11, 13 });

    var rooms: Numbers = .{};
    try support.run(program(fromSlice(&readings), .{ distinct(field(.room)), map(valueOf), forEach(record) }), .{ gpa, memory(), &rooms });
    try rooms.expect(&.{ 10, 11 });
}

const Text = support.Recorder(u8);

fn spell(text: *Text, word: []const u8) void {
    for (word) |byte| text.add(byte);
    text.add(' ');
}

fn spellLine(text: *Text, line: zrx.Line(8)) void {
    spell(text, line.text());
}

fn lineOf(word: []const u8) !zrx.Line(8) {
    return .from(word);
}

test "distinct keeps a copy of a text key, and reads a line by its text" {
    const words: Words = .{ .words = &.{ "pear", "fig", "plum", "pear", "fig", "pea" } };
    var text: Text = .{};
    try support.run(program(words, .{ distinct(itself), forEach(spell) }), .{ gpa, memory(), &text });
    try text.expect("pear fig plum pea ");

    // A line holds its bytes, and what lies behind its text is not part of
    // the key: the buffer the words come from is filled with something else.
    var lines: Text = .{};
    try support.run(program(words, .{ map(lineOf), distinct(itself), forEach(spellLine) }), .{ gpa, memory(), &lines });
    try lines.expect("pear fig plum pea ");
}

test "distinct: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ distinct(itself), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{});

    // Done after two: the source is stopped where the second new key came.
    var pushed: usize = 0;
    const items = [_]u32{ 1, 1, 2, 2, 3, 3 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ distinct(itself), take(2), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ distinct(itself), map(failAt(3)), forEach(record) }), .{ gpa, memory(), &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 1, 2 });
}

/// The items an error path was given.
const Rejected = struct { items: Numbers = .{} };

fn reject(rejected: *Rejected, failed: zrx.Failed(error{Bad}, u32)) void {
    rejected.items.add(failed.item);
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
        distinct(field(.id)),
        map(unmarked),
        forEach(record),
    }), .{ gpa, memory(), &seen, &rejected });
    try seen.expect(&.{8});
    try rejected.items.expect(&.{7});
}

// --- foldBy ---------------------------------------------------------------------

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

test "foldBy folds every key's items and emits the keys in the order they were first seen" {
    const items = [_]u32{ 13, 21, 33, 42, 51, 60, 3 };
    var counts: Counts = .{};
    try support.run(program(fromSlice(&items), .{ foldBy(lastDigit, @as(u32, 0), count), forEach(recordCount) }), .{ gpa, memory(), &counts });
    try expectCounts(&counts, &.{
        .{ .source = 3, .item = 3 },
        .{ .source = 1, .item = 2 },
        .{ .source = 2, .item = 1 },
        .{ .source = 0, .item = 1 },
    });

    var sums: Counts = .{};
    try support.run(program(fromSlice(&items), .{ foldBy(lastDigit, @as(u32, 100), add), forEach(recordCount) }), .{ gpa, memory(), &sums });
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
    try support.run(program(fromSlice(&[_]u32{ 11, 12, 21 }), .{ foldBy(scaledDigit, @as(u32, 0), addScaled), forEach(recordCount) }), .{ gpa, memory(), &sums, Scale{ .by = 3 } });
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 96 },
        .{ .source = 6, .item = 36 },
    });
}

fn spellCount(text: *Text, pair: zrx.Tagged([]const u8, u32)) void {
    for (pair.source) |byte| text.add(byte);
    text.add('0' + @as(u8, @intCast(pair.item)));
    text.add(' ');
}

test "foldBy hands on a copy of a text key" {
    const words: Words = .{ .words = &.{ "pear", "fig", "pear", "plum", "fig", "pear" } };
    var text: Text = .{};
    try support.run(program(words, .{ foldBy(itself, @as(u32, 0), count), forEach(spellCount) }), .{ gpa, memory(), &text });
    try text.expect("pear3 fig2 plum1 ");
}

fn failCount(pair: Count) error{Bad}!Count {
    if (pair.source == 1) return error.Bad;
    return pair;
}

test "foldBy: an empty stream, a pipe that is done, a pipe that fails" {
    var counts: Counts = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ foldBy(lastDigit, @as(u32, 0), count), forEach(recordCount) }), .{ gpa, memory(), &counts });
    try expectCounts(&counts, &.{});

    // Nothing is emitted before the end, so the source runs out; the pipe
    // after it is done with the first key.
    var pushed: usize = 0;
    const items = [_]u32{ 13, 21, 33, 42 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ foldBy(lastDigit, @as(u32, 0), count), take(1), forEach(recordCount) }), .{ gpa, memory(), &counts });
    try expectCounts(&counts, &.{.{ .source = 3, .item = 2 }});
    try std.testing.expectEqual(@as(usize, 4), pushed);

    var failed: Counts = .{};
    const result = support.run(program(fromSlice(&items), .{ foldBy(lastDigit, @as(u32, 0), count), map(failCount), forEach(recordCount) }), .{ gpa, memory(), &failed });
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
        recover(error{Bad}, .{forEach(reject)}),
        foldBy(lastDigit, @as(u32, 0), addSmall),
        forEach(recordCount),
    }), .{ gpa, memory(), &sums, &rejected });
    try rejected.items.expect(&.{ 105, 203 });
    try expectCounts(&sums, &.{
        .{ .source = 3, .item = 36 },
        .{ .source = 4, .item = 44 },
    });
}

// --- sorted ---------------------------------------------------------------------

test "sorted pushes the stream in order when it ends" {
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    var up: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(ascending(itself)), forEach(record) }), .{ gpa, memory(), &up });
    try up.expect(&.{ 4, 5, 9, 15, 26, 31 });

    var down: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(descending(itself)), forEach(record) }), .{ gpa, memory(), &down });
    try down.expect(&.{ 31, 26, 15, 9, 5, 4 });
}

test "sorted: items the order does not tell apart keep the order they came in" {
    const items = [_]u32{ 31, 42, 11, 22, 41, 12, 21 };
    var up: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(ascending(lastDigit)), forEach(record) }), .{ gpa, memory(), &up });
    try up.expect(&.{ 31, 11, 41, 21, 42, 22, 12 });

    var down: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ sorted(descending(lastDigit)), forEach(record) }), .{ gpa, memory(), &down });
    try down.expect(&.{ 42, 22, 12, 31, 11, 41, 21 });
}

const Near = struct { to: u32 };

fn nearer(near: Near, a: u32, b: u32) bool {
    return @max(a, near.to) - @min(a, near.to) < @max(b, near.to) - @min(b, near.to);
}

test "sorted takes an order of the caller's own, with its dependencies" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{ 1, 20, 9, 14, 11 }), .{ sorted(nearer), forEach(record) }), .{ gpa, memory(), &seen, Near{ .to = 10 } });
    try seen.expect(&.{ 9, 11, 14, 1, 20 });
}

const Level = enum(u8) { debug = 1, warn = 5, info = 3 };
const Event = struct { level: Level, heat: f32, id: u32 };

fn idOf(event: Event) u32 {
    return event.id;
}

test "sorted orders by text, by the value of an enum tag and by a float" {
    const words: Words = .{ .words = &.{ "pear", "fig", "plum", "pea", "figs" } };
    var text: Text = .{};
    try support.run(program(words, .{ map(lineOf), sorted(ascending(itself)), forEach(spellLine) }), .{ gpa, memory(), &text });
    try text.expect("fig figs pea pear plum ");

    const events = [_]Event{
        .{ .level = .warn, .heat = 0.5, .id = 1 },
        .{ .level = .debug, .heat = -2.0, .id = 2 },
        .{ .level = .info, .heat = 9.25, .id = 3 },
    };
    var by_level: Numbers = .{};
    try support.run(program(fromSlice(&events), .{ sorted(ascending(field(.level))), map(idOf), forEach(record) }), .{ gpa, memory(), &by_level });
    try by_level.expect(&.{ 2, 3, 1 });

    var by_heat: Numbers = .{};
    try support.run(program(fromSlice(&events), .{ sorted(descending(field(.heat))), map(idOf), forEach(record) }), .{ gpa, memory(), &by_heat });
    try by_heat.expect(&.{ 3, 1, 2 });
}

test "sorted: an empty stream, a pipe that is done, a pipe that fails" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ sorted(ascending(itself)), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{});

    // It has to see everything before it can push anything.
    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ sorted(ascending(itself)), take(2), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    // Stopped before it: it sorts what it was given.
    var first: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ take(3), sorted(ascending(itself)), forEach(record) }), .{ gpa, memory(), &first });
    try first.expect(&.{ 4, 15, 31 });

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ sorted(ascending(itself)), map(failAt(15)), forEach(record) }), .{ gpa, memory(), &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 4, 5, 9 });
}

// --- top ------------------------------------------------------------------------

test "top keeps the first items of an order and pushes them in that order" {
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    var largest: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ top(3, descending(itself)), forEach(record) }), .{ gpa, memory(), &largest });
    try largest.expect(&.{ 31, 26, 15 });

    var smallest: Numbers = .{};
    try support.run(program(fromSlice(&items), .{ top(2, ascending(itself)), forEach(record) }), .{ gpa, memory(), &smallest });
    try smallest.expect(&.{ 4, 5 });
}

test "top emits what sorted and take emit, for every count and with ties" {
    var random: std.Random.DefaultPrng = .init(0x7a7278);
    var items: [40]u32 = undefined;
    for ([_]usize{ 0, 1, 2, 7, 40 }) |len| {
        // Few distinct keys, so that most items tie with others.
        for (items[0..len]) |*item| item.* = random.random().uintLessThan(u32, 90);
        for ([_]usize{ 0, 1, 2, 3, 5, 39, 40, 41, 1000 }) |limit| {
            inline for (.{ ascending(lastDigit), descending(lastDigit), ascending(itself) }) |order| {
                var kept: Numbers = .{};
                try support.run(program(fromSlice(items[0..len]), .{ top(limit, order), forEach(record) }), .{ gpa, memory(), &kept });
                var wanted: Numbers = .{};
                try support.run(program(fromSlice(items[0..len]), .{ sorted(order), take(limit), forEach(record) }), .{ gpa, memory(), &wanted });
                try kept.expect(wanted.slice());
            }
        }
    }
}

test "top: an empty stream, a pipe that is done, a pipe that fails, a count of none" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ top(3, ascending(itself)), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{});

    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ top(4, ascending(itself)), take(2), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ top(4, ascending(itself)), map(failAt(9)), forEach(record) }), .{ gpa, memory(), &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 4, 5 });

    // Nothing will ever be pushed on: the source is stopped at once, and no
    // memory is asked for.
    pushed = 0;
    var none: Numbers = .{};
    var counted = std.testing.FailingAllocator.init(gpa, .{});
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ top(0, ascending(itself)), forEach(record) }), .{ counted.allocator(), memory(), &none });
    try none.expect(&.{});
    try std.testing.expectEqual(@as(usize, 1), pushed);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
}

// --- takeLast -------------------------------------------------------------------

test "takeLast pushes the last items in the order they came" {
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 10), .{ takeLast(3), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 7, 8, 9 });

    // Exactly as many, and fewer than asked for.
    var all: Numbers = .{};
    try support.run(program(range(u32, 0, 4), .{ takeLast(4), forEach(record) }), .{ gpa, memory(), &all });
    try support.run(program(range(u32, 0, 2), .{ takeLast(4), forEach(record) }), .{ gpa, memory(), &all });
    try all.expect(&.{ 0, 1, 2, 3, 0, 1 });
}

test "takeLast: an empty stream, a pipe that is done, a pipe that fails, a count of none" {
    var seen: Numbers = .{};
    try support.run(program(fromSlice(&[_]u32{}), .{ takeLast(3), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{});

    var pushed: usize = 0;
    const items = [_]u32{ 31, 4, 15, 9, 26, 5 };
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ takeLast(4), take(2), forEach(record) }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 15, 9 });
    try std.testing.expectEqual(@as(usize, 6), pushed);

    var failed: Numbers = .{};
    const result = support.run(program(fromSlice(&items), .{ takeLast(4), map(failAt(26)), forEach(record) }), .{ gpa, memory(), &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{ 15, 9 });

    pushed = 0;
    var none: Numbers = .{};
    var counted = std.testing.FailingAllocator.init(gpa, .{});
    try support.run(program(Counting{ .items = &items, .pushed = &pushed }, .{ takeLast(0), forEach(record) }), .{ counted.allocator(), memory(), &none });
    try none.expect(&.{});
    try std.testing.expectEqual(@as(usize, 1), pushed);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
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
        foldBy(lastDigit, @as(u32, 0), count),
        top(3, descending(field(.item))),
        forEach(recordCount),
    }), .{ gpa, memory(), &counts });
    try expectCounts(&counts, &.{
        .{ .source = 1, .item = 4 },
        .{ .source = 3, .item = 3 },
        .{ .source = 2, .item = 2 },
    });

    var seen: Numbers = .{};
    try support.run(program(fromSlice(&items), .{
        filter(isOdd),
        distinct(lastDigit),
        sorted(descending(itself)),
        takeLast(2),
        forEach(record),
    }), .{ gpa, memory(), &seen });
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
        zrx.each(firstDigits, .{ map(mirrored), sorted(ascending(itself)) }),
        map(field(.item)),
        forEach(record),
    }), .{ gpa, memory(), &seen });
    try seen.expect(&.{ 0, 2, 99, 0, 2, 97, 99 });
}

test "inside each, the one buffer of sorted, top or takeLast is used again for the next item" {
    // 400 items of 500 numbers each: kept all at once that is 800 000 bytes.
    inline for (.{
        pipe(.{sorted(descending(itself))}),
        pipe(.{top(500, descending(itself))}),
        pipe(.{takeLast(500)}),
    }) |held| {
        var counted = std.testing.FailingAllocator.init(gpa, .{});
        var total: u32 = 0;
        try support.run(program(range(u32, 0, 400), .{
            zrx.each(constantRange, held),
            map(field(.item)),
            fold(@as(u32, 0), add),
            forEach(keep),
        }), .{ counted.allocator(), memory(), &total });
        try std.testing.expectEqual(@as(u32, 400 * (499 * 500 / 2)), total);
        try std.testing.expect(counted.allocated_bytes < 100_000);
    }
}

fn constantRange(_: u32) @TypeOf(range(u32, 0, 0)) {
    return range(u32, 0, 500);
}

fn keep(total: *u32, value: u32) void {
    total.* = value;
}

test "in the sub-pipes of a branch each operator has a state of its own" {
    var low: Numbers = .{};
    var high: support.Recorder(u64) = .{};
    try support.run(program(fromSlice(&[_]u32{ 31, 4, 15, 9, 26, 5 }), .{zrx.branch(.{
        .{ top(2, ascending(itself)), forEach(record) },
        .{ top(2, descending(itself)), map(widen), forEach(support.record(u64)) },
    })}), .{ gpa, memory(), &low, &high });
    try low.expect(&.{ 4, 5 });
    try high.expect(&.{ 31, 26 });
}

fn widen(value: u32) u64 {
    return value;
}

test "behind a queue the operators run on its task, and a failure there gives the memory back" {
    const io = std.testing.io;
    var seen: Numbers = .{};
    try support.run(program(range(u32, 0, 200), .{
        distinct(lastDigit),
        zrx.queue(4),
        sorted(descending(itself)),
        takeLast(3),
        forEach(record),
    }), .{ io, gpa, memory(), &seen });
    try seen.expect(&.{ 2, 1, 0 });

    var failed: Numbers = .{};
    const result = support.run(program(range(u32, 0, 200), .{
        zrx.queue(4),
        distinct(lastDigit),
        map(failAt(7)),
        sorted(ascending(itself)),
        forEach(record),
    }), .{ io, gpa, memory(), &failed });
    try std.testing.expectError(error.Bad, result);
    try failed.expect(&.{});
}
