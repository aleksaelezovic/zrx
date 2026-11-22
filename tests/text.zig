//! `zrx.ext.text`: text items tidied and taken apart.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;
const text = zrx.ext.text;
const pattern = zrx.ext.pattern;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const fold = zrx.fold;
const take = zrx.take;
const skip = zrx.skip;
const queue = zrx.queue;
const each = zrx.each;
const recover = zrx.recover;
const forEach = zrx.forEach;
const compose = zrx.compose;
const field = zrx.field;
const require = zrx.require;

const Row = zrx.Line(16);
const Word = zrx.Line(8);

/// What `handler` answers for `item`: these handlers have no dependencies.
fn ask(comptime handler: type, item: anytype) @TypeOf(handler.call({}, .{item})) {
    return handler.call({}, .{item});
}

fn row(comptime whole: []const u8) Row {
    return Row.from(whole) catch unreachable;
}

const Texts = support.Recorder([]const u8);

fn expectTexts(expected: []const []const u8, seen: *const Texts) !void {
    try std.testing.expectEqual(expected.len, seen.len);
    for (expected, seen.slice()) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectLines(comptime T: type, expected: []const []const u8, seen: *const support.Recorder(T)) !void {
    try std.testing.expectEqual(expected.len, seen.len);
    for (expected, seen.slice()) |want, *got| try std.testing.expectEqualStrings(want, got.text());
}

// --- trim ------------------------------------------------------------------------

test "trim strips the bytes it names at both ends and nothing between them" {
    const trimmed = text.trim(" \t");
    try std.testing.expectEqualStrings("a b", ask(trimmed, @as([]const u8, " \ta b\t ")));
    try std.testing.expectEqualStrings("a b", ask(trimmed, @as([]const u8, "a b")));
    try std.testing.expectEqualStrings("", ask(trimmed, @as([]const u8, " \t \t")));
    try std.testing.expectEqualStrings("", ask(trimmed, @as([]const u8, "")));
    // A byte that is not named stays, at the edge too.
    try std.testing.expectEqualStrings("\na\r", ask(trimmed, @as([]const u8, " \na\r ")));
}

test "trimStart and trimEnd strip one end" {
    const whole: []const u8 = "--a-b--";
    try std.testing.expectEqualStrings("a-b--", ask(text.trimStart("-"), whole));
    try std.testing.expectEqualStrings("--a-b", ask(text.trimEnd("-"), whole));
    try std.testing.expectEqualStrings("a-b", ask(text.trim("-"), whole));
}

test "whitespace is what std.ascii counts as such" {
    try std.testing.expectEqualStrings("a", ask(text.trim(text.whitespace), @as([]const u8, " \t\r\n\x0b\x0ca\x0c\x0b\n\r\t ")));
    try std.testing.expectEqualStrings(&std.ascii.whitespace, text.whitespace);
}

test "what is kept of a []const u8 is a slice of the same bytes" {
    const whole: []const u8 = "  abc ";
    const kept = ask(text.trim(" "), whole);
    try std.testing.expectEqual([]const u8, @TypeOf(kept));
    try std.testing.expectEqual(whole.ptr + 2, kept.ptr);
    try std.testing.expectEqual(3, kept.len);
}

test "a string literal and a slice with a sentinel are text" {
    try std.testing.expectEqualStrings("a", ask(text.trim(" "), " a "));
    const ended: [:0]const u8 = " a ";
    try std.testing.expectEqualStrings("a", ask(text.trim(" "), ended));
    var bytes = " a ".*;
    const mutable: []u8 = &bytes;
    try std.testing.expectEqualStrings("a", ask(text.trim(" "), mutable));
}

test "what is kept of a line is a line of the same length limit" {
    const kept = ask(text.trim(" "), row("  abc "));
    try std.testing.expectEqual(Row, @TypeOf(kept));
    try std.testing.expectEqualStrings("abc", kept.text());
    try std.testing.expectEqualStrings("abc ", ask(text.trimStart(" "), row("  abc ")).text());
    try std.testing.expectEqualStrings("  abc", ask(text.trimEnd(" "), row("  abc ")).text());
    try std.testing.expectEqualStrings("", ask(text.trim(" "), row("    ")).text());
    try std.testing.expectEqualStrings("", ask(text.trim(" "), row("")).text());
    // A line that is full is still a line when nothing is stripped.
    try std.testing.expectEqualStrings("0123456789abcdef", ask(text.trim(" "), row("0123456789abcdef")).text());
}

test "a trimmed line is a value: it crosses a queue" {
    const rows = [_]Row{ row(" a "), row("b\t"), row(" \t "), row("c d") };
    var seen: support.Recorder(Row) = .{};
    try support.run(program(fromSlice(&rows), .{
        map(text.trim(" \t")),
        queue(1),
        forEach(support.record(Row)),
    }), .{ io, &seen });
    try expectLines(Row, &.{ "a", "b", "", "c d" }, &seen);
}

test "a trimmed []const u8 goes on down the pipe as it is" {
    const wholes = [_][]const u8{ " a ", "b", "  " };
    var seen: Texts = .{};
    program(fromSlice(&wholes), .{
        map(text.trim(" ")),
        forEach(support.record([]const u8)),
    }).run(.{&seen});
    try expectTexts(&.{ "a", "b", "" }, &seen);
}

test "a line reached by reference is trimmed where it is: Row.text goes first" {
    const rows = [_]Row{ row("  ab "), row("c") };
    const references = [_]*const Row{ &rows[0], &rows[1] };
    var seen: Texts = .{};
    program(fromSlice(&references), .{
        map(compose(.{ Row.text, text.trim(" ") })),
        forEach(support.record([]const u8)),
    }).run(.{&seen});
    try expectTexts(&.{ "ab", "c" }, &seen);
    // A slice of the row itself, not of a copy of it.
    try std.testing.expectEqual(@as([*]const u8, &rows[0].bytes) + 2, seen.items[0].ptr);
}

// --- ASCII case ------------------------------------------------------------------

test "toUpper and toLower convert the ASCII letters and leave every other byte" {
    try std.testing.expectEqualStrings("AB-1 Z{`", ask(text.toUpper, row("ab-1 Z{`")).text());
    try std.testing.expectEqualStrings("ab-1 z[@", ask(text.toLower, row("AB-1 z[@")).text());
    try std.testing.expectEqualStrings("", ask(text.toUpper, row("")).text());
    // The bytes of UTF-8 are not ASCII letters: `é` stays what it is.
    try std.testing.expectEqualStrings("CAF\xc3\xa9", ask(text.toUpper, row("caf\xc3\xa9")).text());
    try std.testing.expectEqualStrings("\xc3\x89t\xc3\xa9", ask(text.toLower, row("\xc3\x89T\xc3\xa9")).text());
    try std.testing.expectEqual(Row, @TypeOf(ask(text.toUpper, row("a"))));
}

test "every byte is converted as std.ascii converts it" {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, value| byte.* = @intCast(value);
    const all = try zrx.Line(256).from(&bytes);
    for (ask(text.toUpper, all).text(), ask(text.toLower, all).text(), bytes) |upper, lower, byte| {
        try std.testing.expectEqual(std.ascii.toUpper(byte), upper);
        try std.testing.expectEqual(std.ascii.toLower(byte), lower);
    }
}

test "the case of a []const u8 is converted in a line of its own" {
    const wholes = [_][]const u8{ "ab-1", "", "Zed" };
    var seen: support.Recorder(Word) = .{};
    try support.run(program(fromSlice(&wholes), .{
        map(compose(.{ Word.from, text.toUpper })),
        forEach(support.record(Word)),
    }), .{&seen});
    try expectLines(Word, &.{ "AB-1", "", "ZED" }, &seen);
}

test "a text too long for the line it is to be converted in fails the item" {
    const wholes = [_][]const u8{ "short", "far too long" };
    var seen: support.Recorder(Word) = .{};
    try std.testing.expectError(error.StreamTooLong, support.run(program(fromSlice(&wholes), .{
        map(compose(.{ Word.from, text.toLower })),
        forEach(support.record(Word)),
    }), .{&seen}));
    try expectLines(Word, &.{"short"}, &seen);
}

test "the transforms compose: a line trimmed, then in upper case" {
    const rows = [_]Row{ row("  ab-1 "), row("x") };
    var seen: support.Recorder(Row) = .{};
    program(fromSlice(&rows), .{
        map(compose(.{ text.trim(" "), text.toUpper })),
        forEach(support.record(Row)),
    }).run(.{&seen});
    try expectLines(Row, &.{ "AB-1", "X" }, &seen);
}

// --- split and tokenize ----------------------------------------------------------

/// The pieces `source_of` makes of `whole`.
fn piecesOf(comptime source_of: type, whole: []const u8) Texts {
    var seen: Texts = .{};
    program(fromValue(whole), .{
        each(source_of, .{skip(0)}),
        map(field(.item)),
        forEach(support.record([]const u8)),
    }).run(.{&seen});
    return seen;
}

test "split gives every piece between two delimiters, the empty ones included" {
    const comma = text.split(",");
    try expectTexts(&.{ "a", "b", "c" }, &piecesOf(comma, "a,b,c"));
    try expectTexts(&.{ "a", "", "c" }, &piecesOf(comma, "a,,c"));
    try expectTexts(&.{ "", "a", "" }, &piecesOf(comma, ",a,"));
    try expectTexts(&.{ "", "" }, &piecesOf(comma, ","));
    try expectTexts(&.{"abc"}, &piecesOf(comma, "abc"));
    // A text without a delimiter is one piece, and so is an empty text.
    try expectTexts(&.{""}, &piecesOf(comma, ""));
}

test "a delimiter of several bytes is that sequence" {
    const separated = text.split(", ");
    try expectTexts(&.{ "a", "b,c", "d" }, &piecesOf(separated, "a, b,c, d"));
    try expectTexts(&.{ "a,", "" }, &piecesOf(separated, "a,, "));
    try expectTexts(&.{ "a", "b" }, &piecesOf(text.split("\r\n"), "a\r\nb"));
}

test "tokenize gives the pieces that hold no delimiter, and no empty one" {
    const words = text.tokenize(" ");
    try expectTexts(&.{ "a", "b", "c" }, &piecesOf(words, "a b c"));
    try expectTexts(&.{ "a", "b" }, &piecesOf(words, "  a   b "));
    try expectTexts(&.{"abc"}, &piecesOf(words, "abc"));
    try expectTexts(&.{}, &piecesOf(words, "   "));
    try expectTexts(&.{}, &piecesOf(words, ""));
}

test "the delimiters of tokenize are bytes, any of which separates" {
    try expectTexts(&.{ "a", "b", "c" }, &piecesOf(text.tokenize(" \t,"), "a, b\t,\tc"));
    try expectTexts(&.{ "a", "b" }, &piecesOf(text.tokenize(text.whitespace), "\ta\r\n b\n"));
    // Where `split` would see the sequence.
    try expectTexts(&.{ "a", "b", "c", "d" }, &piecesOf(text.tokenize(", "), "a, b,c, d"));
}

test "a piece of a []const u8 is a slice of the same bytes" {
    const whole: []const u8 = "ab,cd";
    const seen = piecesOf(text.split(","), whole);
    try std.testing.expectEqual(whole.ptr, seen.items[0].ptr);
    try std.testing.expectEqual(whole.ptr + 3, seen.items[1].ptr);
}

fn count(sum: usize, _: []const u8) usize {
    return sum + 1;
}

test "the sub-pipe runs afresh for every line: a fold there counts the columns of one" {
    const rows = [_]Row{ row("a,b,c"), row(""), row("x,y") };
    var seen: support.Recorder(usize) = .{};
    program(fromSlice(&rows), .{
        each(text.split(","), .{fold(@as(usize, 0), count)}),
        map(field(.item)),
        forEach(support.record(usize)),
    }).run(.{&seen});
    try seen.expect(&.{ 3, 1, 2 });
}

const Column = struct { of: Row, piece: Word };

fn keepColumn(columns: *support.Recorder(Column), column: zrx.Tagged(Row, []const u8)) !void {
    columns.add(.{ .of = column.source, .piece = try .from(column.item) });
}

test "the pieces of a line are there for the stages after the each, with the line" {
    const rows = [_]Row{ row("a, b"), row("cd") };
    var seen: support.Recorder(Column) = .{};
    try support.run(program(fromSlice(&rows), .{
        each(text.split(","), .{map(text.trim(" "))}),
        forEach(keepColumn),
    }), .{&seen});
    try std.testing.expectEqual(3, seen.len);
    for ([_][2][]const u8{ .{ "a, b", "a" }, .{ "a, b", "b" }, .{ "cd", "cd" } }, seen.slice()) |want, *got| {
        try std.testing.expectEqualStrings(want[0], got.of.text());
        try std.testing.expectEqualStrings(want[1], got.piece.text());
    }
}

fn longest(kept: []const u8, piece: []const u8) []const u8 {
    return if (piece.len > kept.len) piece else kept;
}

test "a piece the sub-pipe keeps is there in what the each emits at the end of the line" {
    const rows = [_]Row{ row("a,bcd,ef"), row("gh") };
    var seen: support.Recorder(Column) = .{};
    try support.run(program(fromSlice(&rows), .{
        each(text.split(","), .{fold(@as([]const u8, ""), longest)}),
        forEach(keepColumn),
    }), .{&seen});
    try std.testing.expectEqual(2, seen.len);
    for ([_][2][]const u8{ .{ "a,bcd,ef", "bcd" }, .{ "gh", "gh" } }, seen.slice()) |want, *got| {
        try std.testing.expectEqualStrings(want[0], got.of.text());
        try std.testing.expectEqualStrings(want[1], got.piece.text());
    }
}

test "what is made of the pieces as values crosses a queue" {
    const rows = [_]Row{ row(" a ,b"), row("c") };
    var seen: support.Recorder(Word) = .{};
    try support.run(program(fromSlice(&rows), .{
        each(text.split(","), .{
            map(text.trim(" ")),
            map(compose(.{ Word.from, text.toUpper })),
        }),
        map(field(.item)),
        queue(1),
        forEach(support.record(Word)),
    }), .{ io, &seen });
    try expectLines(Word, &.{ "A", "B", "C" }, &seen);
}

test "a sub-pipe that is done ends its line, and the next line starts afresh" {
    const rows = [_]Row{ row("a,b,c,d"), row("e"), row("f,g,h") };
    var seen: support.Recorder(Word) = .{};
    try support.run(program(fromSlice(&rows), .{
        each(text.split(","), .{
            take(2),
            map(Word.from),
        }),
        map(field(.item)),
        forEach(support.record(Word)),
    }), .{&seen});
    try expectLines(Word, &.{ "a", "b", "e", "f", "g" }, &seen);
}

const Made = struct { pieces: usize = 0 };

fn made(counter: *Made, _: []const u8) void {
    counter.pieces += 1;
}

test "the pipe after the each being done stops the pieces in the middle of a line" {
    inline for (.{ text.split(","), text.tokenize(",") }) |source_of| {
        const rows = [_]Row{ row("a,b,c"), row("d,e,f"), row("g") };
        var counter: Made = .{};
        var seen: support.Recorder(Word) = .{};
        try support.run(program(fromSlice(&rows), .{
            each(source_of, .{
                tap(made),
                map(Word.from),
            }),
            map(field(.item)),
            take(4),
            forEach(support.record(Word)),
        }), .{ &counter, &seen });
        try expectLines(Word, &.{ "a", "b", "c", "d" }, &seen);
        // Neither `e` nor `f` was made, and the last line was not asked for.
        try std.testing.expectEqual(4, counter.pieces);
    }
}

/// A value of the caller's own that holds its text.
const Path = struct {
    bytes: [12]u8,
    len: usize,

    fn of(comptime whole: []const u8) Path {
        var path: Path = .{ .bytes = undefined, .len = whole.len };
        @memcpy(path.bytes[0..whole.len], whole);
        return path;
    }

    pub fn text(path: *const Path) []const u8 {
        return path.bytes[0..path.len];
    }
};

test "a value of one's own that reads its text with text() is taken apart as a line is" {
    const paths = [_]Path{ Path.of("/usr/lib"), Path.of("etc") };
    var seen: support.Recorder(Word) = .{};
    try support.run(program(fromSlice(&paths), .{
        each(text.tokenize("/"), .{map(Word.from)}),
        map(field(.item)),
        forEach(support.record(Word)),
    }), .{&seen});
    try expectLines(Word, &.{ "usr", "lib", "etc" }, &seen);
}

const Tagged = struct { id: u32, tags: Row };

fn tagCount(counts: *support.Recorder([2]usize), counted: zrx.Tagged(Tagged, usize)) void {
    counts.add(.{ counted.source.id, counted.item });
}

test "the text of a field is taken apart after the handler that yields it" {
    const items = [_]Tagged{ .{ .id = 7, .tags = row("a b") }, .{ .id = 9, .tags = row("  ") } };
    var seen: support.Recorder([2]usize) = .{};
    program(fromSlice(&items), .{
        each(compose(.{ field(.tags), text.tokenize(" ") }), .{fold(@as(usize, 0), count)}),
        forEach(tagCount),
    }).run(.{&seen});
    try seen.expect(&.{ .{ 7, 2 }, .{ 9, 0 } });
}

test "a piece is text like any other: a pattern is put to it" {
    const number = pattern.repeat(pattern.digit, .{ .min = 1 });
    const rows = [_]Row{ row("12 ab 7"), row("x"), row("1 2 3") };
    var seen: support.Recorder(usize) = .{};
    program(fromSlice(&rows), .{
        each(text.tokenize(" "), .{
            filter(number),
            fold(@as(usize, 0), count),
        }),
        map(field(.item)),
        forEach(support.record(usize)),
    }).run(.{&seen});
    try seen.expect(&.{ 2, 0, 3 });
}

test "the pieces of a line reached by reference point into that line" {
    const rows = [_]Row{ row("ab,c"), row("d") };
    const references = [_]*const Row{ &rows[0], &rows[1] };
    var seen: Texts = .{};
    program(fromSlice(&references), .{
        each(compose(.{ Row.text, text.split(",") }), .{skip(0)}),
        map(field(.item)),
        forEach(support.record([]const u8)),
    }).run(.{&seen});
    try expectTexts(&.{ "ab", "c", "d" }, &seen);
    try std.testing.expectEqual(@as([*]const u8, &rows[0].bytes) + 3, seen.items[1].ptr);
}

// --- what the guide shows --------------------------------------------------------

const Name = zrx.Line(8);

/// A row taken column by column: `name, cents`.
const Entry = struct {
    columns: u8 = 0,
    name: Name = undefined,
    cents: u32 = 0,

    fn column(entry: Entry, piece: []const u8) !Entry {
        var next = entry;
        switch (entry.columns) {
            0 => next.name = try .from(piece),
            1 => next.cents = try std.fmt.parseInt(u32, piece, 10),
            else => return error.TooManyColumns,
        }
        next.columns += 1;
        return next;
    }

    fn isWhole(entry: Entry) bool {
        return entry.columns == 2;
    }
};

const Rejections = support.Recorder(anyerror);

fn rejected(rejections: *Rejections, failed: anytype) void {
    rejections.add(failed.err);
}

fn total(sum: u32, entry: Entry) u32 {
    return sum + entry.cents;
}

fn store(out: *u32, sum: u32) void {
    out.* = sum;
}

const entries = pipe(.{
    recover(anyerror, .{forEach(rejected)}),
    each(text.split(","), .{
        map(text.trim(" \t")),
        fold(Entry{}, Entry.column),
    }),
    map(field(.item)),
    map(require(Entry.isWhole, error.MissingColumn)),
    fold(@as(u32, 0), total),
    forEach(store),
});

test "the guide's example: a line becomes a record column by column, and says which rule it broke" {
    const rows = [_]Row{
        row("ada , 42"),
        row("bob"),
        row("cy,1,2"),
        row("dee,x"),
        row("far too long,1"),
        row("\teve,\t8"),
    };
    var rejections: Rejections = .{};
    var sum: u32 = 0;
    try support.run(program(fromSlice(&rows), entries), .{ &rejections, &sum });
    try std.testing.expectEqual(50, sum);
    try rejections.expect(&.{ error.MissingColumn, error.TooManyColumns, error.InvalidCharacter, error.StreamTooLong });
}

// --- what is a pattern already ---------------------------------------------------

test "a suffix is a pattern only after bytes that cannot be in it" {
    // `seq(.{ repeat(byte, .{}), ".zig" })` does not compile: the `repeat`
    // would take the suffix too. This one ends before the dot.
    const zig_file = pattern.seq(.{ pattern.repeat(pattern.except(pattern.set(".")), .{}), ".zig" });
    const wholes = [_][]const u8{ "a.zig", ".zig", "a.zig.zig", "a.b.zig", "a.zi", "zig" };
    var seen: Texts = .{};
    program(fromSlice(&wholes), .{
        filter(zig_file),
        forEach(support.record([]const u8)),
    }).run(.{&seen});
    // A name with a dot of its own ends in `.zig` and is not described.
    try expectTexts(&.{ "a.zig", ".zig" }, &seen);
}

test "a text that starts with some text, or is it, is a pattern" {
    const starts = pattern.seq(.{ "ab", pattern.repeat(pattern.byte, .{}) });
    const is = pattern.seq(.{"ab"});
    const wholes = [_][]const u8{ "ab", "abc", "xab", "a", "" };
    inline for (.{ .{ starts, 2 }, .{ is, 1 } }) |case| {
        var seen: Texts = .{};
        program(fromSlice(&wholes), .{
            filter(case[0]),
            forEach(support.record([]const u8)),
        }).run(.{&seen});
        try std.testing.expectEqual(case[1], seen.len);
    }
}
