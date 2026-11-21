//! `zrx.ext.pattern`: what a text looks like, and what to take out of it.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const pattern = zrx.ext.pattern;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const recover = zrx.recover;
const forEach = zrx.forEach;
const all = zrx.all;
const not = zrx.not;
const compose = zrx.compose;
const field = zrx.field;
const require = zrx.require;

const seq = pattern.seq;
const oneOf = pattern.oneOf;
const repeat = pattern.repeat;
const optional = pattern.optional;
const extract = pattern.extract;
const int = pattern.int;
const set = pattern.set;
const between = pattern.between;
const except = pattern.except;
const byte = pattern.byte;
const digit = pattern.digit;
const lower = pattern.lower;
const upper = pattern.upper;
const alpha = pattern.alpha;
const alnum = pattern.alnum;
const Extracted = pattern.Extracted;

/// What `p` answers for `text`: a pattern is a handler without dependencies.
fn ask(comptime p: type, text: []const u8) @TypeOf(p.call({}, .{text})) {
    return p.call({}, .{text});
}

fn expectAll(comptime p: type, comptime holds: bool, texts: []const []const u8) !void {
    for (texts) |text| {
        std.testing.expectEqual(holds, ask(p, text)) catch |err| {
            std.debug.print("text: \"{s}\"\n", .{text});
            return err;
        };
    }
}

// --- what a text looks like ------------------------------------------------------

test "a pattern describes the whole text, not a part of it" {
    const greeting = seq(.{ "hello", " ", "world" });
    try expectAll(greeting, true, &.{"hello world"});
    try expectAll(greeting, false, &.{ "", "hello", "hello world!", " hello world", "hello  world", "Hello world" });
}

test "a set is one byte of those named, and its complement with except" {
    try expectAll(set("-_"), true, &.{ "-", "_" });
    try expectAll(set("-_"), false, &.{ "", "a", "--" });
    try expectAll(between('a', 'f'), true, &.{ "a", "c", "f" });
    try expectAll(between('a', 'f'), false, &.{ "g", "A", "`" });
    try expectAll(except(set("/?")), true, &.{ "a", " ", "\x00", "\xff" });
    try expectAll(except(set("/?")), false, &.{ "/", "?", "" });
    try expectAll(byte, true, &.{ "a", "\n", "\xff" });
    try expectAll(byte, false, &.{ "", "ab" });
}

test "the named sets are the ASCII ones" {
    try expectAll(digit, true, &.{ "0", "9" });
    try expectAll(digit, false, &.{ "/", ":", "a" });
    try expectAll(lower, true, &.{ "a", "z" });
    try expectAll(lower, false, &.{ "A", "`", "{" });
    try expectAll(upper, true, &.{ "A", "Z" });
    try expectAll(upper, false, &.{ "a", "@", "[" });
    try expectAll(alpha, true, &.{ "a", "Z" });
    try expectAll(alpha, false, &.{ "0", "_", "\xe9" });
    try expectAll(alnum, true, &.{ "a", "Z", "5" });
    try expectAll(alnum, false, &.{ "_", "-", " " });
}

test "choices of one byte each are one set" {
    // A set again, so `except` takes it.
    const name_byte = oneOf(.{ alnum, set("-_") });
    try expectAll(repeat(except(name_byte), .{ .min = 1 }), true, &.{ " ", "/?." });
    try expectAll(repeat(except(name_byte), .{ .min = 1 }), false, &.{ "a", " a", "-" });
}

test "repeat matches between its least and its most" {
    try expectAll(repeat(digit, .{}), true, &.{ "", "1", "123456789" });
    try expectAll(repeat(digit, .{}), false, &.{ "a", "1a" });
    try expectAll(repeat(digit, .{ .min = 1 }), false, &.{""});
    try expectAll(repeat(digit, .{ .min = 2, .max = 3 }), true, &.{ "12", "123" });
    try expectAll(repeat(digit, .{ .min = 2, .max = 3 }), false, &.{ "1", "1234" });
    try expectAll(repeat(digit, .{ .min = 4, .max = 4 }), true, &.{"2026"});
    try expectAll(repeat(digit, .{ .min = 4, .max = 4 }), false, &.{ "202", "20261" });
    // A pattern of more than one byte, and one whose width varies.
    try expectAll(repeat("ab", .{ .min = 1, .max = 2 }), true, &.{ "ab", "abab" });
    try expectAll(repeat("ab", .{ .min = 1, .max = 2 }), false, &.{ "", "a", "aba", "ababab" });
    const word = seq(.{ repeat(lower, .{ .min = 1 }), "," });
    try expectAll(repeat(word, .{ .min = 2, .max = 3 }), true, &.{ "a,bc,", "a,b,c," });
    try expectAll(repeat(word, .{ .min = 2, .max = 3 }), false, &.{ "a,", "a,b,c,d,", "a,b" });
}

test "a bound of repeat that no text reaches is a bound like any other" {
    // In bytes, each of these is more than a `usize` counts.
    const most = std.math.maxInt(usize);
    const half = most / 2 + 1;
    inline for (.{ most, half }) |bound| {
        try expectAll(repeat("ab", .{ .max = bound }), true, &.{ "", "ab", "abab" });
        try expectAll(repeat("ab", .{ .max = bound }), false, &.{ "a", "aba" });
        try expectAll(repeat("ab", .{ .min = bound }), false, &.{ "", "ab", "abab" });
        try expectAll(repeat("ab", .{ .min = bound, .max = bound }), false, &.{ "", "abab" });
        const twice = repeat(digit, .{ .min = bound, .max = bound });
        try expectAll(seq(.{ twice, twice }), false, &.{ "", "12" });
    }
    try expectAll(repeat(digit, .{ .max = most }), true, &.{ "", "2026" });
    const word = seq(.{ repeat(lower, .{ .min = 1 }), "," });
    try expectAll(repeat(word, .{ .max = most }), true, &.{ "", "a,bc," });
    try expectAll(repeat(word, .{ .min = most }), false, &.{ "", "a,bc," });
}

test "a date is three runs of digits of fixed length" {
    const date = seq(.{
        repeat(digit, .{ .min = 4, .max = 4 }),
        "-",
        repeat(digit, .{ .min = 2, .max = 2 }),
        "-",
        repeat(digit, .{ .min = 2, .max = 2 }),
    });
    try expectAll(date, true, &.{ "2026-11-21", "0000-00-00" });
    try expectAll(date, false, &.{ "2026-11-2", "2026-11-211", "2026/11/21", "2026-1a-21", "" });
}

test "oneOf takes the first choice that matches" {
    const level = oneOf(.{ "info", "warn", "error" });
    try expectAll(level, true, &.{ "info", "warn", "error" });
    try expectAll(level, false, &.{ "", "inf", "warning", "debug" });
    const sign = seq(.{ optional(set("+-")), repeat(digit, .{ .min = 1 }) });
    try expectAll(sign, true, &.{ "5", "+5", "-50" });
    try expectAll(sign, false, &.{ "+", "--5", "5-" });
}

test "what matched is not given back: a repeat keeps what it took and a choice is taken for good" {
    // A regular expression would give the `x` back and match "abx".
    const greedy = seq(.{ repeat(lower, .{ .max = 3 }), "x" });
    try expectAll(greedy, true, &.{"abcx"});
    try expectAll(greedy, false, &.{ "abx", "ax", "x" });
    // And would try "a" once "ab" left nothing for "bc".
    const committed = seq(.{ oneOf(.{ "ab", "a" }), "bc" });
    try expectAll(committed, true, &.{
        "abbc",
    });
    try expectAll(committed, false, &.{"abc"});
}

test "a text that makes a backtracking matcher try every split is one pass here" {
    const p = seq(.{ repeat(oneOf(.{ "aa", "a" }), .{ .min = 1 }), "b" });
    var text: [4097]u8 = @splat('a');
    try std.testing.expect(!ask(p, &text));
    text[4096] = 'b';
    try std.testing.expect(ask(p, &text));
}

test "what two choices share can be written once, and describes the same texts" {
    // The first reads the rest of the letters in every round before it
    // settles for one: the square of the length. The second reads them once.
    const shout = seq(.{ repeat(lower, .{ .min = 1 }), "!" });
    const twice = repeat(oneOf(.{ shout, lower }), .{});
    const once = repeat(seq(.{ repeat(lower, .{ .min = 1 }), optional("!") }), .{});
    const texts: []const []const u8 = &.{ "", "a", "a!", "ab!c", "ab!c!", "a!b!c", "abc", "!", "a!!", "!a", "a!b!!", "aB", "a! " };
    for (texts) |text| {
        std.testing.expectEqual(ask(twice, text), ask(once, text)) catch |err| {
            std.debug.print("text: \"{s}\"\n", .{text});
            return err;
        };
    }
    try expectAll(once, true, &.{ "", "a", "ab!c!" });
    try expectAll(once, false, &.{ "!", "a!!", "aB" });
}

// --- numbers -----------------------------------------------------------------------

test "int matches a decimal number that fits its type" {
    try expectAll(int(u8), true, &.{ "0", "7", "255", "007", "0255" });
    try expectAll(int(u8), false, &.{ "", "256", "1000", "-1", "+1", "1a", " 1", "0x1" });
    try expectAll(int(i8), true, &.{ "0", "127", "-128", "-0", "-007" });
    try expectAll(int(i8), false, &.{ "128", "-129", "-", "--1", "+1" });
    try expectAll(int(u64), true, &.{"18446744073709551615"});
    try expectAll(int(u64), false, &.{ "18446744073709551616", "99999999999999999999999" });
    try expectAll(int(u4), true, &.{ "0", "9", "15" });
    try expectAll(int(u4), false, &.{ "16", "20", "100" });
    try expectAll(int(i5), true, &.{ "15", "-16" });
    try expectAll(int(i5), false, &.{ "16", "-17" });
}

// --- what a pattern extracts --------------------------------------------------------

const address = seq(.{
    extract(.host, repeat(except(set(":/")), .{ .min = 1 })),
    optional(seq(.{ ":", extract(.port, int(u16)) })),
    optional(seq(.{ "/", extract(.offset, int(i8)) })),
});

test "the struct of what a pattern extracts is inferred from it" {
    const Address = Extracted(address);
    try std.testing.expectEqual([]const u8, @FieldType(Address, "host"));
    try std.testing.expectEqual(?u16, @FieldType(Address, "port"));
    try std.testing.expectEqual(?i8, @FieldType(Address, "offset"));
    try std.testing.expectEqual(3, @typeInfo(Address).@"struct".field_names.len);
    // The same pattern is the same type, wherever it is asked for.
    try std.testing.expect(Extracted(address) == Address);
    try std.testing.expect(@TypeOf(ask(address, "x")) == ?Address);
    // A pattern that extracts nothing answers `bool`.
    try std.testing.expect(@TypeOf(ask(digit, "1")) == bool);
}

test "a part that may be absent is null, and one that is there has its value" {
    const whole = ask(address, "example.org:8443/-128").?;
    try std.testing.expectEqualStrings("example.org", whole.host);
    try std.testing.expectEqual(8443, whole.port);
    try std.testing.expectEqual(-128, whole.offset);
    const bare = ask(address, "example.org").?;
    try std.testing.expectEqual(null, bare.port);
    try std.testing.expectEqual(null, bare.offset);
    const offset_only = ask(address, "h/5").?;
    try std.testing.expectEqual(null, offset_only.port);
    try std.testing.expectEqual(5, offset_only.offset);
    inline for (.{ "", "example.org:", "example.org:70000", "example.org/-129", ":80", "a:1:2" }) |text| {
        try std.testing.expectEqual(null, ask(address, text));
    }
}

test "extracted text points into the item" {
    const text: []const u8 = "example.org:80";
    const found = ask(address, text).?;
    try std.testing.expectEqual(text.ptr, found.host.ptr);
    try std.testing.expectEqual(@as(usize, 11), found.host.len);
}

test "an extract may hold others, and one of nothing is empty text" {
    const pair = seq(.{ extract(.whole, seq(.{ extract(.key, repeat(lower, .{ .min = 1 })), "=", extract(.value, repeat(digit, .{})) })), ";" });
    const found = ask(pair, "width=;").?;
    try std.testing.expectEqualStrings("width=", found.whole);
    try std.testing.expectEqualStrings("width", found.key);
    try std.testing.expectEqualStrings("", found.value);
}

test "what a choice extracted before it failed is taken back" {
    const p = seq(.{
        oneOf(.{
            seq(.{ extract(.number, int(u32)), "!" }),
            extract(.word, repeat(alnum, .{ .min = 1 })),
        }),
        optional(seq(.{ " ", extract(.rest, int(u8)), "." })),
    });
    const number = ask(p, "42!").?;
    try std.testing.expectEqual(@as(?u32, 42), number.number);
    try std.testing.expectEqual(null, number.word);
    // The first choice read 42 and then found no `!`.
    const word = ask(p, "42").?;
    try std.testing.expectEqual(null, word.number);
    try std.testing.expectEqualStrings("42", word.word.?);
    // The optional part read 7 and then found no `.`: the whole does not match,
    // and nothing of it is handed out.
    try std.testing.expectEqual(null, ask(p, "42 7"));
    try std.testing.expectEqual(7, ask(p, "42 7.").?.rest);
}

test "what an optional part extracted before it failed is taken back" {
    const p = seq(.{
        extract(.word, repeat(lower, .{ .min = 1 })),
        optional(seq(.{ extract(.number, int(u8)), "!" })),
        extract(.rest, repeat(byte, .{})),
    });
    const with = ask(p, "ab7!x").?;
    try std.testing.expectEqual(@as(?u8, 7), with.number);
    try std.testing.expectEqualStrings("x", with.rest);
    // The optional part read 7 and then found no `!`: it is not in the text,
    // and the 7 belongs to what follows.
    const without = ask(p, "ab7x").?;
    try std.testing.expectEqual(null, without.number);
    try std.testing.expectEqualStrings("7x", without.rest);
}

// --- in a pipe ----------------------------------------------------------------------

const record = seq(.{
    extract(.ts_ms, int(u64)),
    "\t",
    extract(.level, oneOf(.{ "info", "warn", "error" })),
    "\t",
    extract(.service, repeat(oneOf(.{ alnum, set("-_") }), .{ .min = 1 })),
    "\t",
    extract(.latency_ms, int(u32)),
    optional("\r"),
});

const log = [_][]const u8{
    "1700000000001\tinfo\tapi-gw\t12",
    "1700000000002\terror\tbilling_v2\t250\r",
    "1700000000003\tdebug\tapi-gw\t1", // not a level
    "1700000000004\twarn\tapi gw\t1", // a space in the service
    "1700000000005\twarn\tauth\t7 ", // a byte after the end
    "1700000000006\twarn\tauth\t8",
};

const Totals = struct { records: u32 = 0, latency_ms: u64 = 0 };

fn add(totals: Totals, entry: Extracted(record)) Totals {
    return .{ .records = totals.records + 1, .latency_ms = totals.latency_ms + entry.latency_ms };
}
fn keep(out: *Totals, totals: Totals) void {
    out.* = totals;
}
fn count(bad: *u32, _: anytype) void {
    bad.* += 1;
}

test "require makes a failure of a text the pattern does not describe" {
    var totals: Totals = .{};
    var bad: u32 = 0;
    try support.run(program(fromSlice(&log), .{
        recover(error{InvalidRecord}, .{forEach(count)}),
        map(require(record, error.InvalidRecord)),
        fold(Totals{}, add),
        forEach(keep),
    }), .{ &totals, &bad });
    try std.testing.expectEqual(Totals{ .records = 3, .latency_ms = 270 }, totals);
    try std.testing.expectEqual(3, bad);
}

test "a case of a route is given what the pattern extracted, with the text" {
    var totals: Totals = .{};
    var bad: u32 = 0;
    try support.run(program(fromSlice(&log), .{
        route(.{
            when(record, .{
                map(field(.found)),
                fold(Totals{}, add),
                forEach(keep),
            }),
            otherwise(.{forEach(count)}),
        }),
    }), .{ &totals, &bad });
    try std.testing.expectEqual(Totals{ .records = 3, .latency_ms = 270 }, totals);
    try std.testing.expectEqual(3, bad);
}

const Line = struct { source: u8, text: []const u8 };
const Slow = struct { count: u32 = 0, source: u8 = 0 };

fn isSlow(entry: Extracted(record)) bool {
    return entry.latency_ms >= 100;
}
fn note(slow: *Slow, hit: zrx.Found(Extracted(record), Line)) void {
    if (!isSlow(hit.found)) return;
    slow.count += 1;
    slow.source = hit.item.source;
}
fn fromSecond(line: Line) bool {
    return line.source == 2;
}

test "a pattern goes last in all, and after the handler that yields the text" {
    var lines: [log.len]Line = undefined;
    for (&lines, log, 0..) |*line, text, i| line.* = .{ .source = @intCast(1 + i % 2), .text = text };
    var slow: Slow = .{};
    const records_of_second = all(.{ fromSecond, compose(.{ field(.text), record }) });
    try support.run(program(fromSlice(&lines), .{
        route(.{when(records_of_second, .{forEach(note)})}),
    }), .{&slow});
    try std.testing.expectEqual(Slow{ .count = 1, .source = 2 }, slow);
}

const Names = support.Recorder([]const u8);
const service_name = repeat(oneOf(.{ alnum, set("-_") }), .{ .min = 1 });

test "a pattern that extracts nothing is a predicate like any other" {
    var seen: Names = .{};
    const names = [_][]const u8{ "api-gw", "", "billing v2", "auth_1", "é" };
    try support.run(program(fromSlice(&names), .{ filter(service_name), forEach(support.record([]const u8)) }), .{&seen});
    try std.testing.expectEqual(2, seen.len);
    try std.testing.expectEqualStrings("auth_1", seen.slice()[1]);
    seen = .{};
    try support.run(program(fromSlice(&names), .{ filter(not(service_name)), forEach(support.record([]const u8)) }), .{&seen});
    try std.testing.expectEqual(3, seen.len);
}

test "a pattern takes text as a slice or as a pointer to an array" {
    var buffer = "/items/42".*;
    const item = seq(.{ "/items/", extract(.id, int(u32)) });
    try std.testing.expectEqual(42, item.call({}, .{@as([]u8, &buffer)}).?.id);
    try std.testing.expectEqual(42, item.call({}, .{&buffer}).?.id);
    try std.testing.expectEqual(42, item.call({}, .{"/items/42"}).?.id);
}
