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
const as = pattern.as;
const recursive = pattern.recursive;
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
    // settles for one: the square of the length. The second is linear.
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

// --- choices with names -----------------------------------------------------------------

const key_value = seq(.{ extract(.key, repeat(lower, .{ .min = 1 })), "=", extract(.value, int(u8)) });
const token = extract(.token, oneOf(.{
    .number = int(u32),
    .pair = key_value,
    .word = as(zrx.Line(8), repeat(lower, .{ .min = 1 })),
    .dash = "-",
}));

test "choices with names are kept as a union that says which one matched" {
    const Token = @FieldType(Extracted(token), "token");
    try std.testing.expectEqual(u32, @FieldType(Token, "number"));
    try std.testing.expectEqual(void, @FieldType(Token, "dash"));
    try std.testing.expectEqual(42, ask(token, "42").?.token.number);
    try std.testing.expectEqualStrings("abc", ask(token, "abc").?.token.word.text());
    try std.testing.expectEqual({}, ask(token, "-").?.token.dash);
    // A choice that extracts holds its own struct.
    const found = ask(token, "ab=7").?.token;
    try std.testing.expectEqualStrings("ab", found.pair.key);
    try std.testing.expectEqual(7, found.pair.value);
    switch (found) {
        .pair => {},
        .number, .word, .dash => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(null, ask(token, "A"));
    try std.testing.expectEqual(null, ask(token, "42x"));
}

test "a choice with a name is taken for good like any other, and what it kept is not carried on" {
    // `ab=7` is a pair although it begins as a word would; `ab=x` is no
    // pair, and the word after it has nothing of the pair.
    const loose = seq(.{ extract(.first, oneOf(.{ .pair = key_value, .word = as(zrx.Line(8), repeat(lower, .{ .min = 1 })) })), extract(.rest, repeat(byte, .{})) });
    try std.testing.expectEqualStrings("ab", ask(loose, "ab=7!").?.first.pair.key);
    const fell = ask(loose, "ab=x").?;
    try std.testing.expectEqualStrings("ab", fell.first.word.text());
    try std.testing.expectEqualStrings("=x", fell.rest);
    // A number too large for the pair's `u8` does not make it a pair.
    try std.testing.expectEqualStrings("=256", ask(loose, "ab=256").?.rest);
}

test "what a named choice extracts and its text has not is null in its struct" {
    const flag = seq(.{ extract(.key, repeat(lower, .{ .min = 1 })), optional(seq(.{ "=", extract(.value, int(u8)) })) });
    const item = extract(.item, oneOf(.{ .number = int(u32), .flag = flag }));
    try std.testing.expectEqual(null, ask(item, "verbose").?.item.flag.value);
    try std.testing.expectEqual(3, ask(item, "level=3").?.item.flag.value.?);
    // Of two extracts in a choice, the one that was not reached.
    const either = seq(.{ "<", oneOf(.{ extract(.digit, digit), extract(.letter, lower) }), ">" });
    const tagged = extract(.item, oneOf(.{ .number = int(u32), .either = either }));
    try std.testing.expectEqualStrings("7", ask(tagged, "<7>").?.item.either.digit.?);
    try std.testing.expectEqual(null, ask(tagged, "<7>").?.item.either.letter);
}

test "choices with names that are not extracted only match, and one that may be absent is optional" {
    const plain = seq(.{ "<", oneOf(.{ .number = int(u32), .dash = "-" }), ">" });
    try expectAll(plain, true, &.{ "<1>", "<->" });
    try expectAll(plain, false, &.{ "<>", "<a>" });
    const maybe = seq(.{ "<", optional(token), ">" });
    try std.testing.expectEqual(null, ask(maybe, "<>").?.token);
    try std.testing.expectEqual(7, ask(maybe, "<7>").?.token.?.number);
}

/// `<a b>` or `<a <b c>>`, the second part a union of the two.
fn choosing(comptime self: type) type {
    return seq(.{
        "<",
        extract(.name, as(zrx.Line(8), repeat(lower, .{ .min = 1 }))),
        " ",
        extract(.object, oneOf(.{ .inner = self, .word = as(zrx.Line(8), repeat(lower, .{ .min = 1 })) })),
        ">",
    });
}

/// The word a term ends in, however deep. Given a pointer: the text of a
/// value is read where the value is, not out of a copy of it.
fn lastWord(level: anytype) []const u8 {
    // Further in than the innermost level there is nothing, and no text gets there.
    if (@TypeOf(level.*) == void) return "";
    return switch (level.object) {
        .word => |*word| word.text(),
        .inner => |*inner| lastWord(inner),
    };
}

test "a rule that holds itself as a named choice is a union at every level" {
    const rule = recursive(choosing, .{ .depth = 3 });
    const texts = [_][]const u8{ "<a <b <c d>>>", "not one", "<x y>" };
    const Seen = support.Recorder(Extracted(rule));
    var seen: Seen = .{};
    try support.run(program(fromSlice(&texts), .{
        map(toRow),
        route(.{
            when(rule, .{
                zrx.queue(1),
                map(field(.found)),
                forEach(support.record(Extracted(rule))),
            }),
            otherwise(.{zrx.drain()}),
        }),
    }), .{ std.testing.io, &seen });
    try std.testing.expectEqual(2, seen.slice().len);
    const deep = seen.slice()[0];
    try std.testing.expectEqualStrings("a", deep.name.text());
    try std.testing.expectEqualStrings("b", deep.object.inner.name.text());
    try std.testing.expectEqualStrings("d", deep.object.inner.object.inner.object.word.text());
    // The innermost level's choice of the rule holds nothing, and is never the one.
    try std.testing.expectEqual(void, @FieldType(@TypeOf(deep.object.inner.object.inner.object), "inner"));
    try std.testing.expectEqualStrings("y", seen.slice()[1].object.word.text());
    try std.testing.expectEqualStrings("d", lastWord(&deep));
    try std.testing.expectEqualStrings("y", lastWord(&seen.slice()[1]));
    try std.testing.expectEqual(null, ask(rule, "<a <b <c <d e>>>>"));
}

// --- a rule that holds itself ----------------------------------------------------------

/// Letters, and groups of them in parentheses.
fn group(comptime self: type) type {
    return seq(.{ "(", repeat(oneOf(.{ lower, self }), .{}), ")" });
}

test "a rule that holds itself matches as deep as its depth, and no deeper" {
    try expectAll(recursive(group, .{ .depth = 1 }), true, &.{ "()", "(abc)" });
    try expectAll(recursive(group, .{ .depth = 1 }), false, &.{ "(a(b))", "(", "a", "" });
    try expectAll(recursive(group, .{ .depth = 3 }), true, &.{ "()", "(a(b)c)", "(a(b(c))(d)e)", "((()))" });
    try expectAll(recursive(group, .{ .depth = 3 }), false, &.{ "(a(b(c(d))))", "(a(b)", "(a))", "(((())))" });
    // Eight levels unless a depth is written.
    try expectAll(recursive(group, .{}), true, &.{"(((((((())))))))"});
    try expectAll(recursive(group, .{}), false, &.{"((((((((()))))))))"});
}

/// Letters and then the rule again, or a `!`.
fn shouted(comptime self: type) type {
    return oneOf(.{ seq(.{ repeat(lower, .{ .min = 1 }), self }), "!" });
}

test "a rule may stand behind a part that takes all it can" {
    // Where the rule is one level too deep it describes nothing, and that
    // is not the mistake of a part that can never match.
    try expectAll(recursive(shouted, .{ .depth = 2 }), true, &.{ "!", "abc!" });
    try expectAll(recursive(shouted, .{ .depth = 2 }), false, &.{ "", "abc", "a!b!" });
}

/// `<a b <c d>>`: a name, and then a word or another one of these.
fn term(comptime self: type) type {
    return seq(.{
        "<",
        extract(.name, repeat(lower, .{ .min = 1 })),
        " ",
        oneOf(.{ extract(.inner, self), extract(.word, repeat(lower, .{ .min = 1 })) }),
        ">",
    });
}

const nested_term = recursive(term, .{ .depth = 3 });

test "what a level of a rule extracts is a struct of its own, with the next level in it" {
    const found = ask(nested_term, "<a <b <c d>>>").?;
    try std.testing.expectEqualStrings("a", found.name);
    try std.testing.expectEqual(null, found.word);
    const second = found.inner.?;
    try std.testing.expectEqualStrings("b", second.name);
    const third = second.inner.?;
    try std.testing.expectEqualStrings("c", third.name);
    try std.testing.expectEqualStrings("d", third.word.?);
    // The innermost level has nothing further in: a `?void` that is never there.
    try std.testing.expectEqual(?void, @TypeOf(third.inner));
    try std.testing.expectEqual(null, third.inner);

    try std.testing.expectEqual(@TypeOf(found), Extracted(nested_term));
    try std.testing.expectEqualStrings("z", ask(nested_term, "<a z>").?.word.?);
    try std.testing.expectEqual(null, ask(nested_term, "<a z>").?.inner);
    try std.testing.expectEqual(null, ask(nested_term, "<a <b <c <d e>>>>"));
    try std.testing.expectEqual(null, ask(nested_term, "<a <b c>"));
    // Alone, a rule describes the whole text like any pattern.
    try std.testing.expectEqual(null, ask(nested_term, "<a z>!"));
}

/// How many levels a term has: each level is a type of its own, so what
/// walks them is generic, and the innermost `self` is a `void`.
fn levels(level: anytype) usize {
    if (@TypeOf(level) == void) return 0;
    return 1 + if (level.inner) |inner| levels(inner) else 0;
}

test "a handler walks the levels of a rule as far as they go" {
    try std.testing.expectEqual(1, levels(ask(nested_term, "<a z>").?));
    try std.testing.expectEqual(3, levels(ask(nested_term, "<a <b <c d>>>").?));
}

test "a rule is a part like any other: extracted it is its struct, and its names clash with none" {
    const said = seq(.{ extract(.name, repeat(lower, .{ .min = 1 })), ": ", extract(.said, nested_term), optional(seq(.{ " ", extract(.again, nested_term) })) });
    const found = ask(said, "x: <a <b c>> <d e>").?;
    try std.testing.expectEqualStrings("x", found.name);
    try std.testing.expectEqualStrings("a", found.said.name);
    try std.testing.expectEqualStrings("c", found.said.inner.?.word.?);
    try std.testing.expectEqualStrings("e", found.again.?.word.?);
    try std.testing.expectEqual(null, ask(said, "x: <a b>").?.again);
    // Not extracted, it is matched and nothing of it is kept.
    const only = seq(.{ extract(.name, repeat(lower, .{ .min = 1 })), ": ", nested_term });
    try std.testing.expectEqualStrings("x", ask(only, "x: <a <b c>>").?.name);
    try std.testing.expectEqual(null, ask(only, "x: <a <b <c <d e>>>>"));
    // And kept as a value of another kind, it is its text.
    const whole = extract(.text, as(zrx.Line(16), nested_term));
    try std.testing.expectEqualStrings("<a <b c>>", ask(whole, "<a <b c>>").?.text.text());
}

test "what a level extracted before the rule failed further in is taken back" {
    // `<c` begins as a third level and is none: the choice goes on to the rest.
    const loose = struct {
        fn rule(comptime self: type) type {
            return seq(.{ "<", extract(.name, repeat(lower, .{ .min = 1 })), " ", oneOf(.{ extract(.inner, self), extract(.rest, repeat(except(set(">")), .{ .min = 1 })) }), ">" });
        }
    };
    const second = ask(recursive(loose.rule, .{ .depth = 3 }), "<a <b <c>>").?.inner.?;
    try std.testing.expectEqualStrings("b", second.name);
    try std.testing.expectEqual(null, second.inner);
    try std.testing.expectEqualStrings("<c", second.rest.?);
}

/// `[a,[b,c]]`: a pair, each side a letter or a pair.
fn pairOf(comptime self: type) type {
    const side = struct {
        fn of(comptime letter: @EnumLiteral(), comptime inner: @EnumLiteral()) type {
            return oneOf(.{ extract(inner, self), extract(letter, lower) });
        }
    };
    return seq(.{ "[", side.of(.left, .left_pair), ",", side.of(.right, .right_pair), "]" });
}

test "a rule may hold itself in more than one place" {
    const tree = recursive(pairOf, .{ .depth = 3 });
    const found = ask(tree, "[[a,b],[c,[d,e]]]").?;
    try std.testing.expectEqualStrings("a", found.left_pair.?.left.?);
    try std.testing.expectEqualStrings("c", found.right_pair.?.left.?);
    try std.testing.expectEqualStrings("e", found.right_pair.?.right_pair.?.right.?);
    try std.testing.expectEqual(null, ask(tree, "[[a,b],[c,[d,[e,f]]]]"));
    // What it extracts has a size, which each level of two doubles.
    try std.testing.expect(@sizeOf(Extracted(recursive(pairOf, .{ .depth = 4 }))) > 2 * @sizeOf(Extracted(tree)));
}

/// `<name word>` or `<name <...>>` out of a line: every part a value.
fn valued(comptime self: type) type {
    return seq(.{
        "<",
        extract(.name, as(Name, repeat(lower, .{ .min = 1 }))),
        " ",
        oneOf(.{ extract(.inner, self), extract(.word, as(Name, repeat(lower, .{ .min = 1 }))) }),
        ">",
    });
}

test "the levels of a rule put to a line are values, and cross a queue" {
    const Terms = support.Recorder(Extracted(recursive(valued, .{ .depth = 3 })));
    var seen: Terms = .{};
    const texts = [_][]const u8{ "<a <b c>>", "not one", "<d e>" };
    try support.run(program(fromSlice(&texts), .{
        map(toRow),
        route(.{
            when(recursive(valued, .{ .depth = 3 }), .{
                zrx.queue(1),
                map(field(.found)),
                forEach(support.record(Extracted(recursive(valued, .{ .depth = 3 })))),
            }),
            otherwise(.{zrx.drain()}),
        }),
    }), .{ std.testing.io, &seen });
    try std.testing.expectEqual(2, seen.slice().len);
    try std.testing.expectEqualStrings("c", seen.slice()[0].inner.?.word.?.text());
    try std.testing.expectEqualStrings("e", seen.slice()[1].word.?.text());
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

// --- what is kept as a value ---------------------------------------------------------

const Name = zrx.Line(8);
const Row = zrx.Line(48);

/// The words of a format, as the values they stand for.
const Level = enum {
    info,
    warn,
    failure,

    pub fn from(text: []const u8) error{UnknownLevel}!Level {
        const words: std.StaticStringMap(Level) = .initComptime(.{ .{ "info", .info }, .{ "warn", .warn }, .{ "error", .failure } });
        return words.get(text) orelse error.UnknownLevel;
    }
};

/// A type whose `from` cannot fail.
const Length = struct {
    bytes: usize,

    pub fn from(text: []const u8) Length {
        return .{ .bytes = text.len };
    }
};

const letters = repeat(lower, .{ .min = 1 });

test "as keeps what a part matched as a value its type makes from the text" {
    const entry = seq(.{ extract(.level, as(Level, letters)), " ", extract(.name, as(Name, letters)), " ", extract(.rest, as(Length, repeat(byte, .{}))) });
    const Entry = Extracted(entry);
    try std.testing.expectEqual(Level, @FieldType(Entry, "level"));
    try std.testing.expectEqual(Name, @FieldType(Entry, "name"));
    const found = ask(entry, "error api and more").?;
    try std.testing.expectEqual(Level.failure, found.level);
    try std.testing.expectEqualStrings("api", found.name.text());
    try std.testing.expectEqual(8, found.rest.bytes);
}

test "a text its type does not make a value of does not match" {
    const named = seq(.{ extract(.name, as(Name, letters)), "!" });
    try std.testing.expectEqualStrings("abcdefgh", ask(named, "abcdefgh!").?.name.text());
    try std.testing.expectEqual(null, ask(named, "abcdefghi!"));
    // Without an extract it is still asked: the pattern describes a name that fits.
    try expectAll(as(Name, letters), true, &.{ "a", "abcdefgh" });
    try expectAll(as(Name, letters), false, &.{ "", "abcdefghi", "A" });
    try expectAll(as(Level, letters), true, &.{ "info", "error" });
    try expectAll(as(Level, letters), false, &.{ "failure", "debug" });
    // A choice goes on to the next where the value is not made.
    const either = oneOf(.{ extract(.level, as(Level, letters)), extract(.name, as(Name, letters)) });
    try std.testing.expectEqual(Level.warn, ask(either, "warn").?.level.?);
    try std.testing.expectEqual(null, ask(either, "other").?.level);
    try std.testing.expectEqualStrings("other", ask(either, "other").?.name.?.text());
}

test "a value is a copy: it stays when the text it was taken from is gone" {
    const named = extract(.name, as(Name, letters));
    var text: [5]u8 = "first".*;
    const found = ask(named, &text).?;
    @memcpy(&text, "other");
    try std.testing.expectEqualStrings("first", found.name.text());
}

test "a part that can match nothing and can still refuse may be made optional" {
    // On `x` the part matches the byte and refuses it; the optional then takes nothing.
    const maybe = optional(as(zrx.Line(0), optional("x")));
    try expectAll(maybe, true, &.{""});
    try expectAll(maybe, false, &.{"x"});
    try expectAll(seq(.{ maybe, "x" }), true, &.{"x"});
    try expectAll(seq(.{ maybe, "x" }), false, &.{ "", "xx" });
    // What it kept before it refused is taken back.
    const kept = seq(.{ optional(extract(.none, as(zrx.Line(0), optional("x")))), extract(.rest, repeat(byte, .{})) });
    try std.testing.expectEqual(null, ask(kept, "x").?.none);
    try std.testing.expectEqualStrings("x", ask(kept, "x").?.rest);
}

/// A value whose `from` keeps the text it was given, and one that holds such a value.
const Borrowed = struct {
    text: []const u8,

    pub fn from(text: []const u8) Borrowed {
        return .{ .text = text };
    }
};
const Wrapped = struct {
    inside: ?[1]Borrowed,

    pub fn from(text: []const u8) Wrapped {
        return .{ .inside = .{.from(text)} };
    }
};

test "a value with a pointer in it is taken out of a text that stays, where it points" {
    const text: []const u8 = "abc!";
    const found = ask(seq(.{ extract(.name, as(Borrowed, letters)), "!" }), text).?;
    try std.testing.expectEqual(text.ptr, found.name.text.ptr);
    try std.testing.expectEqualStrings("abc", found.name.text);
    const deep = ask(seq(.{ extract(.name, as(Wrapped, letters)), "!" }), text).?;
    try std.testing.expectEqual(text.ptr, deep.name.inside.?[0].text.ptr);
}

test "a choice that can match nothing and can still refuse does not hide the next" {
    // `as` refuses the byte its part matched: nothing fits a line of none.
    const refusing = as(zrx.Line(0), optional("x"));
    try expectAll(refusing, true, &.{""});
    try expectAll(refusing, false, &.{"x"});
    try expectAll(oneOf(.{ refusing, "x" }), true, &.{ "", "x" });
    // The same through the parts that pass it on.
    try expectAll(oneOf(.{ seq(.{ refusing, optional("-") }), "x" }), true, &.{ "", "-", "x" });
    const kept = oneOf(.{ extract(.none, refusing), extract(.one, "x") });
    try std.testing.expectEqualStrings("x", ask(kept, "x").?.one.?);
    try std.testing.expectEqual(null, ask(kept, "x").?.none);
    const named = extract(.which, oneOf(.{ .none = refusing, .one = "x" }));
    try std.testing.expectEqual({}, ask(named, "x").?.which.one);
    // And it may stand in a choice that is not last, of a choice. Where it
    // does match nothing it is taken for good: `y` is left over.
    try expectAll(oneOf(.{ oneOf(.{ refusing, "y" }), "x" }), true, &.{ "", "x" });
    try expectAll(oneOf(.{ oneOf(.{ refusing, "y" }), "x" }), false, &.{"y"});
}

// --- an item that holds its text ------------------------------------------------------

const reading = seq(.{ extract(.sensor, as(Name, letters)), ",", extract(.ts_ms, int(u64)), ",", extract(.temp_mc, int(i32)), optional("\r") });
const Reading = Extracted(reading);

fn askRow(comptime p: type, text: []const u8) !@TypeOf(p.call({}, .{text})) {
    return p.call({}, .{try Row.from(text)});
}

test "a pattern is put to the text of a line" {
    try std.testing.expect(try askRow(letters, "abc"));
    try std.testing.expect(!try askRow(letters, "abc1"));
    try std.testing.expect(!try askRow(letters, ""));
    const found = (try askRow(reading, "north,1700,-2500\r")).?;
    try std.testing.expectEqualStrings("north", found.sensor.text());
    try std.testing.expectEqual(1700, found.ts_ms);
    try std.testing.expectEqual(-2500, found.temp_mc);
    try std.testing.expectEqual(null, try askRow(reading, "north,1700"));
    try std.testing.expectEqual(null, try askRow(reading, "northernmost,1700,1"));
}

const rows = [_][]const u8{ "north,1,-2500", "south,2,300", "not a reading", "north,3,700", "south,4" };

fn toRow(text: []const u8) !Row {
    return Row.from(text);
}

const Readings = support.Recorder(Reading);
const Rows = support.Recorder(Row);

fn isNorth(found: Reading) bool {
    return std.mem.eql(u8, found.sensor.text(), "north");
}

fn expectReadings(seen: *const Readings, bad: *const Rows) !void {
    try std.testing.expectEqual(2, seen.slice().len);
    try std.testing.expectEqual(1, seen.slice()[0].ts_ms);
    try std.testing.expectEqual(-2500, seen.slice()[0].temp_mc);
    try std.testing.expectEqualStrings("north", seen.slice()[1].sensor.text());
    try std.testing.expectEqual(700, seen.slice()[1].temp_mc);
    try std.testing.expectEqual(2, bad.slice().len);
    try std.testing.expectEqualStrings("not a reading", bad.slice()[0].text());
    try std.testing.expectEqualStrings("south,4", bad.slice()[1].text());
}

test "lines are required to be what a pattern describes, and what it extracted goes on" {
    var seen: Readings = .{};
    var bad: Rows = .{};
    try support.run(program(fromSlice(&rows), .{
        map(toRow),
        recover(error{InvalidReading}, .{ map(field(.item)), forEach(support.record(Row)) }),
        map(require(reading, error.InvalidReading)),
        filter(isNorth),
        forEach(support.record(Reading)),
    }), .{ &seen, &bad });
    try expectReadings(&seen, &bad);
}

test "what a line's case is given are values: they cross a queue with the line" {
    var seen: Readings = .{};
    var bad: Rows = .{};
    try support.run(program(fromSlice(&rows), .{
        map(toRow),
        route(.{
            when(reading, .{
                zrx.queue(1),
                filter(compose(.{ field(.found), isNorth })),
                map(field(.found)),
                forEach(support.record(Reading)),
            }),
            otherwise(.{forEach(support.record(Row))}),
        }),
    }), .{ std.testing.io, &seen, &bad });
    try expectReadings(&seen, &bad);
}

test "the line a case is given is the one its values were taken from" {
    const Pairs = support.Recorder(zrx.Found(Reading, Row));
    var seen: Pairs = .{};
    try support.run(program(fromSlice(&rows), .{
        map(toRow),
        route(.{
            when(reading, .{forEach(support.record(zrx.Found(Reading, Row)))}),
            otherwise(.{zrx.drain()}),
        }),
    }), .{&seen});
    try std.testing.expectEqual(3, seen.slice().len);
    try std.testing.expectEqualStrings("south,2,300", seen.slice()[1].item.text());
    try std.testing.expectEqualStrings("south", seen.slice()[1].found.sensor.text());
}

test "a line that came with something else is reached through its field" {
    const Sided = zrx.Tagged(u8, Row);
    const side = struct {
        fn of(row: Row) Sided {
            return .{ .source = 7, .item = row };
        }
        fn north(seen: zrx.Found(Reading, Sided)) bool {
            return seen.item.source == 7 and isNorth(seen.found);
        }
    };
    var seen: Readings = .{};
    try support.run(program(fromSlice(&rows), .{
        map(toRow),
        map(side.of),
        route(.{
            when(compose(.{ field(.item), reading }), .{
                filter(side.north),
                map(field(.found)),
                forEach(support.record(Reading)),
            }),
            otherwise(.{zrx.drain()}),
        }),
    }), .{&seen});
    try std.testing.expectEqual(2, seen.slice().len);
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
