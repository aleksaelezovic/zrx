//! What a line of N-Quads looks like, and what is kept of it.
//!
//! The grammar is RDF 1.1 N-Quads, with the triple terms of RDF 1.2 as
//! objects. It is written with `zrx.ext.pattern`: every rule below is a
//! value, and `statement` is the pattern a line is put to.
const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

const seq = pattern.seq;
const oneOf = pattern.oneOf;
const repeat = pattern.repeat;
const optional = pattern.optional;
const extract = pattern.extract;
const as = pattern.as;
const set = pattern.set;
const between = pattern.between;
const except = pattern.except;
const digit = pattern.digit;
const alpha = pattern.alpha;
const alnum = pattern.alnum;

/// The longest line, not counting its newline, and the longest term.
pub const max_line = 512;
pub const max_term = 256;
/// How deep a triple term may hold another.
pub const max_nesting = 4;

/// A term as it is written, held as a value.
pub const Term = zrx.Line(max_term);

// --- escapes ---------------------------------------------------------------------

const hex = oneOf(.{ digit, between('a', 'f'), between('A', 'F') });
/// `\u00E9`, `\U0001F600`
const uchar = oneOf(.{
    seq(.{ "\\u", repeat(hex, .{ .min = 4, .max = 4 }) }),
    seq(.{ "\\U", repeat(hex, .{ .min = 8, .max = 8 }) }),
});
/// `\n`, `\"`, `\\`
const echar = seq(.{ "\\", set("tbnrf\"'\\") });

// --- terms -----------------------------------------------------------------------

/// `<http://example.org/s>`. An IRI here is absolute: it begins with a
/// scheme and a colon, which a relative one such as `<s>` has not.
const scheme = seq(.{ alpha, repeat(oneOf(.{ alnum, set("+-.") }), .{}) });
const iri_byte = except(oneOf(.{ between(0, ' '), set("<>\"{}|^`\\") }));
const iri = seq(.{ "<", scheme, ":", repeat(oneOf(.{ iri_byte, uchar }), .{}), ">" });

/// `_:b1`, `_:a.b`. Bytes of UTF-8 beyond ASCII are taken as letters.
const name_start = oneOf(.{ alnum, set("_:"), between(0x80, 0xFF) });
const name = oneOf(.{ name_start, set("-") });
/// Dots only inside a label: a round that ends on a dot takes nothing, so
/// the dot that ends a statement is left to it.
const dotted = seq(.{ repeat(".", .{ .min = 1 }), repeat(name, .{ .min = 1 }) });
const blank_node = seq(.{ "_:", name_start, repeat(name, .{}), repeat(dotted, .{}) });

/// `"chat"`, `"chat"@fr-BE`, `"1"^^<http://www.w3.org/2001/XMLSchema#integer>`
const string_byte = except(set("\"\\\n\r"));
const string = seq(.{ "\"", repeat(oneOf(.{ string_byte, echar, uchar }), .{}), "\"" });
const language = seq(.{ repeat(alpha, .{ .min = 1 }), repeat(seq(.{ "-", repeat(alnum, .{ .min = 1 }) }), .{}) });
const literal = seq(.{
    string,
    optional(oneOf(.{
        seq(.{ "^^", iri }),
        seq(.{ "@", language }),
    })),
});

const ws = repeat(set(" \t"), .{});

/// `<<( <s> <p> "o" )>>`, whose object may be another one, `depth` deep. A
/// pattern cannot contain itself; a function can build one from a shallower
/// one, and the depth is then written and not the text's to choose.
fn tripleTerm(comptime depth: usize) type {
    const plain = oneOf(.{ iri, blank_node, literal });
    const object = if (depth == 0) plain else oneOf(.{ tripleTerm(depth - 1), plain });
    return seq(.{ "<<(", ws, oneOf(.{ iri, blank_node }), ws, iri, ws, object, ws, ")>>" });
}

// --- a line ----------------------------------------------------------------------

const comment = seq(.{ "#", repeat(except(set("\n\r")), .{}) });
const line_end = seq(.{ ws, optional(comment), optional("\r") });

/// A line that holds no statement: nothing, or a comment.
pub const empty = line_end;

/// `subject predicate object graph? .`
pub const statement = seq(.{
    ws,
    extract(.subject, as(Term, oneOf(.{ iri, blank_node }))),
    ws,
    extract(.predicate, as(Term, iri)),
    ws,
    extract(.object, as(Term, oneOf(.{ tripleTerm(max_nesting - 1), iri, blank_node, literal }))),
    ws,
    optional(seq(.{ extract(.graph, as(Term, oneOf(.{ iri, blank_node }))), ws })),
    ".",
    line_end,
});

/// What a statement holds, read off its pattern:
/// `{ subject: Term, predicate: Term, object: Term, graph: ?Term }`.
pub const Quad = pattern.Extracted(statement);

/// A statement written the one way: a space between its terms, nothing after its dot.
pub const Tidy = struct {
    quad: Quad,

    pub fn of(quad: Quad) Tidy {
        return .{ .quad = quad };
    }

    /// How many bytes `format` writes.
    pub fn length(tidy: *const Tidy) usize {
        const quad = &tidy.quad;
        const graph = if (quad.graph) |*graph| " ".len + graph.len else 0;
        return quad.subject.len + " ".len + quad.predicate.len + " ".len + quad.object.len + graph + " .".len;
    }

    /// Whether it is a line this can read again. Writing a statement the
    /// one way can make it longer: a space is put where there was none.
    pub fn fits(tidy: Tidy) bool {
        return tidy.length() <= max_line;
    }

    pub fn format(tidy: Tidy, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{f} {f} {f} ", .{ tidy.quad.subject, tidy.quad.predicate, tidy.quad.object });
        if (tidy.quad.graph) |graph| try writer.print("{f} ", .{graph});
        try writer.writeAll(".");
    }
};

// --- tests -----------------------------------------------------------------------

const Line = zrx.Line(max_line);
const Seen = struct { quad: ?Quad = null, empty: bool = false };

fn keep(seen: *Seen, quad: Quad) void {
    seen.quad = quad;
}

fn noteEmpty(seen: *Seen, _: Line) void {
    seen.empty = true;
}

fn ignore(_: Line) void {}

/// What the grammar makes of one line.
fn read(text: []const u8) !Seen {
    var seen: Seen = .{};
    zrx.program(zrx.fromValue(try Line.from(text)), .{zrx.route(.{
        zrx.when(empty, .{zrx.forEach(noteEmpty)}),
        zrx.when(statement, .{ zrx.map(zrx.field(.found)), zrx.forEach(keep) }),
        zrx.otherwise(.{zrx.forEach(ignore)}),
    })}).run(.{&seen});
    return seen;
}

fn expectTidy(expected: []const u8, text: []const u8) !void {
    const quad = (try read(text)).quad orelse {
        std.debug.print("not a statement: {s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    var buffer: [max_line]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buffer, "{f}", .{Tidy.of(quad)}));
}

test "a statement is three terms, or four with its graph" {
    const quad = (try read("<http://ex.org/s> <http://ex.org/p> \"chat\"@fr-BE <http://ex.org/g> . # a cat")).quad.?;
    try std.testing.expectEqualStrings("<http://ex.org/s>", quad.subject.text());
    try std.testing.expectEqualStrings("<http://ex.org/p>", quad.predicate.text());
    try std.testing.expectEqualStrings("\"chat\"@fr-BE", quad.object.text());
    try std.testing.expectEqualStrings("<http://ex.org/g>", quad.graph.?.text());
    try std.testing.expectEqual(null, (try read("_:a <x:p> _:b .")).quad.?.graph);
}

test "a statement is written the one way whatever stood between its terms" {
    try expectTidy("<x:s> <x:p> <x:o> .", "<x:s> <x:p> <x:o> .");
    try expectTidy("<x:s> <x:p> <x:o> .", "\t<x:s>   <x:p>\t<x:o>  .  # said twice\r");
    try expectTidy("<x:s> <x:p> <x:o> .", "<x:s><x:p><x:o>.");
    try expectTidy("_:a <x:p> _:b _:g .", "_:a <x:p> _:b _:g.");
    try expectTidy("_:a.b <x:p> \"1\\n\\u00E9\"^^<http://www.w3.org/2001/XMLSchema#string> .", "_:a.b <x:p> \"1\\n\\u00E9\"^^<http://www.w3.org/2001/XMLSchema#string>.");
    try expectTidy("<x:s> <x:p> \"\" <x:g> .", "<x:s> <x:p> \"\" <x:g> .");
    try expectTidy("<x:s> <x:p> \"caf\xc3\xa9 # no comment\" .", "<x:s> <x:p> \"caf\xc3\xa9 # no comment\" .");
}

test "a triple term is an object, and may hold another to a depth" {
    try expectTidy("<x:s> <x:says> <<( <x:a> <x:p> \"c\" )>> .", "<x:s> <x:says> <<( <x:a> <x:p> \"c\" )>> .");
    try expectTidy("<x:s> <x:says> <<(<x:a> <x:p> <<(_:b <x:q> <<(<x:c> <x:r> <<(<x:d> <x:t> <x:e>)>>)>>)>>)>> <x:g> .", "<x:s> <x:says> <<(<x:a> <x:p> <<(_:b <x:q> <<(<x:c> <x:r> <<(<x:d> <x:t> <x:e>)>>)>>)>>)>> <x:g> .");
    for ([_][]const u8{
        // One deeper than `max_nesting`.
        "<x:s> <x:says> <<(<x:a> <x:p> <<(<x:b> <x:q> <<(<x:c> <x:r> <<(<x:d> <x:t> <<(<x:e> <x:u> <x:f>)>>)>>)>>)>>)>> .",
        "<x:s> <x:says> <<( <x:a> <x:p> \"c\" .",
        "<<( <x:a> <x:p> <x:c> )>> <x:says> <x:o> .",
        "<x:s> <x:says> <<( \"a\" <x:p> <x:c> )>> .",
    }) |text| try std.testing.expectEqual(null, (try read(text)).quad);
}

test "what is not a statement" {
    for ([_][]const u8{
        "<x:s> <x:p> <x:o>",
        "<x:s> <x:p> .",
        "\"s\" <x:p> <x:o> .",
        "<x:s> _:p <x:o> .",
        "<x:s> <x:p> \"o\" \"g\" .",
        "<x:s> <x:p> <x:o> <x:g> <x:h> .",
        "<x:s> <x:p> \"unterminated .",
        "<x:s> <x:p> \"bad \\x escape\" .",
        "<x:s> <x:p> \"o\"@ .",
        "<x:s> <x:p> \"o\"^^_:b .",
        "<x:s with space> <x:p> <x:o> .",
        "<x:s> <x:p> <x:o> . junk",
        "<x:s> <x:p> \"\\u12\" .",
        "_:a. <x:p> <x:o> .",
    }) |text| {
        const seen = try read(text);
        std.testing.expect(seen.quad == null and !seen.empty) catch |err| {
            std.debug.print("line: {s}\n", .{text});
            return err;
        };
    }
}

test "a line with nothing or a comment holds no statement" {
    for ([_][]const u8{ "", "   ", "\t# only a comment", "# <x:s> <x:p> <x:o> .", "\r", " # with\ttabs\r" }) |text| {
        try std.testing.expect((try read(text)).empty);
    }
}

test "a term longer than a Term is no statement" {
    const long = "<x:" ++ @as([max_term - 3]u8, @splat('x')) ++ ">";
    try std.testing.expectEqual(null, (try read(long ++ " <x:p> <x:o> .")).quad);
    const fits = "<x:" ++ @as([max_term - 4]u8, @splat('x')) ++ ">";
    try std.testing.expectEqualStrings(fits, (try read(fits ++ " <x:p> <x:o> .")).quad.?.subject.text());
}

test "an IRI is absolute: it begins with a scheme" {
    for ([_][]const u8{
        "<urn:isbn:1> <x:p> <x:o> .",
        "<a+b-c.d1:x> <x:p> <x:o> .",
        "<x:> <x:p> <x:o> .",
        "<x:s> <x:p> \"1\"^^<xsd:integer> .",
    }) |text| try std.testing.expect((try read(text)).quad != null);
    for ([_][]const u8{
        "<relative> <x:p> <x:o> .",
        "<x:s> <p> <x:o> .",
        "<x:s> <x:p> <o> .",
        "<x:s> <x:p> <x:o> <g> .",
        "<x:s> <x:p> \"1\"^^<integer> .",
        "</path> <x:p> <x:o> .",
        "<1x:s> <x:p> <x:o> .",
        "<:s> <x:p> <x:o> .",
        "<x:s> <x:says> <<( <a> <x:p> <x:o> )>> .",
    }) |text| {
        std.testing.expectEqual(null, (try read(text)).quad) catch |err| {
            std.debug.print("line: {s}\n", .{text});
            return err;
        };
    }
}

test "the length of a tidy statement is what is written of it" {
    for ([_][]const u8{
        "<x:s> <x:p> <x:o> .",
        "<x:s><x:p>\"o\"@en<x:g>.",
        "_:a <x:p> <<(<x:a> <x:p> <<(_:b <x:q> \"c\")>>)>> _:g .",
    }) |text| {
        const tidy: Tidy = .of((try read(text)).quad.?);
        var buffer: [max_line]u8 = undefined;
        try std.testing.expectEqual((try std.fmt.bufPrint(&buffer, "{f}", .{tidy})).len, tidy.length());
    }
}
