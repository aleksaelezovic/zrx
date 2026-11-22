//! Text items tidied and taken apart, on top of `std.mem` and `std.ascii`.
//!
//!     const columns = pipe(.{
//!         each(text.split(","), .{
//!             map(text.trim(" \t")),
//!             fold(Entry{}, Entry.column),
//!         }),
//!         map(field(.item)),
//!     });
//!
//! Two kinds of thing. `trim`, `trimStart`, `trimEnd`, `toUpper` and
//! `toLower` are handlers that give a text back changed. `split` and
//! `tokenize` are handlers that give a source of the pieces of a text, for
//! `each` to run a sub-pipe over.
//!
//! What each is put to, and what it gives back, follows from where the bytes
//! are. A `[]const u8` points at bytes that stay where they are, so a part
//! of it is a slice of the same bytes. A `Line` is a value that holds its
//! bytes, and a handler is given its item by value, so a piece of a line's
//! text lives no longer than the call: what is made of a line is a line.
//! Changing bytes needs bytes of one's own: the case of a `[]const u8` is
//! not converted, a line's is.
//!
//! `docs/spec-text.md` is the design record.
//!
//! Bytes only: the classes and the case are ASCII's, and a byte that is not
//! ASCII is left as it is.
//!
//! Nothing here is known to the core: these are composite handlers and a
//! source.
const std = @import("std");
const di = @import("../di.zig");
const Line = @import("../io.zig").Line;

/// The bytes `std.ascii` counts as whitespace, for `trim` and `tokenize`:
/// space, tab, line feed, carriage return, vertical tab and form feed.
pub const whitespace: []const u8 = &std.ascii.whitespace;

/// A text that stays where it is: a slice of bytes, or a pointer to an
/// array of them, as a string literal is.
fn isText(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (info.size) {
        .slice => info.child == u8,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Whether `T` is a `Line(n)`: the one value of text that is made here.
fn isLine(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "bytes")) return false;
    return switch (@typeInfo(@FieldType(T, "bytes"))) {
        .array => |array| array.child == u8 and T == Line(array.len),
        else => false,
    };
}

/// Whether `T` is a struct that holds a text of its own and reads it with
/// `pub fn text(*const T) []const u8`, as a `Line` does. Told by name, as
/// the pattern extension tells it: it is what a caller's own struct may
/// declare.
fn holdsText(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "text")) return false;
    const reads = switch (@typeInfo(@TypeOf(T.text))) {
        .@"fn" => |reads| reads,
        else => return false,
    };
    return reads.param_types.len == 1 and reads.param_types[0] == *const T and reads.return_type == []const u8;
}

/// How a handler that is put to something else is told to get at the text.
fn before(comptime who: []const u8, comptime argument: []const u8) []const u8 {
    return "; put the handler that yields the text before it, as in `compose(.{ field(.name), text." ++ who ++ argument ++ " })`";
}

// ---------------------------------------------------------------------------
// trim
// ---------------------------------------------------------------------------

const Side = enum { both, start, end };

/// The item without the bytes of `strip` at its start and at its end:
/// `map(text.trim(" \t"))`, or `map(text.trim(text.whitespace))`.
///
/// Put to a `[]const u8` it answers a slice of the same bytes. Put to a
/// `Line(n)` it answers a `Line(n)`: a handler is given its item by value,
/// and a piece of a line's text lives no longer than the call.
pub fn trim(comptime strip: []const u8) type {
    return Trim("trim", .both, strip);
}

/// `trim`, at the start of the text only.
pub fn trimStart(comptime strip: []const u8) type {
    return Trim("trimStart", .start, strip);
}

/// `trim`, at the end of the text only: `map(text.trimEnd("\r"))`.
pub fn trimEnd(comptime strip: []const u8) type {
    return Trim("trimEnd", .end, strip);
}

fn Trim(comptime who: []const u8, comptime side: Side, comptime strip: []const u8) type {
    if (strip.len == 0) @compileError(who ++ ": no bytes to strip; name them, as in `text." ++ who ++ "(\" \\t\")` or `text." ++ who ++ "(text.whitespace)`");
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Trimmed(di.types(@TypeOf(args))) {
            if (comptime isText(@TypeOf(args[0]))) return kept(args[0]);
            // What is kept points into the line this handler was given by
            // value, and is no longer than that line, so it fits a new one.
            // Made here and not by `from`, which would ask whether it fits:
            // that is a branch never taken and two more copies of the line.
            const part = kept(args[0].text());
            var line: @TypeOf(args[0]) = .{ .bytes = undefined, .len = part.len };
            @memcpy(line.bytes[0..part.len], part);
            return line;
        }

        fn kept(whole: []const u8) []const u8 {
            return switch (side) {
                .both => std.mem.trim(u8, whole, strip),
                .start => std.mem.trimStart(u8, whole, strip),
                .end => std.mem.trimEnd(u8, whole, strip),
            };
        }

        /// A slice for a text that stays where it is, a line for a line.
        /// Part of the type of `call`, so that it is checked where the
        /// handler is used.
        fn Trimmed(comptime Args: []const type) type {
            if (Args.len == 1) {
                if (isText(Args[0])) return []const u8;
                if (isLine(Args[0])) return Args[0];
            }
            @compileError(
                who ++ ": is put to one item that is text, a `[]const u8` or a `zrx.Line(n)`, got " ++ di.listTypes(Args) ++ before(who, "(\" \\t\")"),
            );
        }
    };
}

// ---------------------------------------------------------------------------
// ASCII case
// ---------------------------------------------------------------------------

const Letters = enum { upper, lower };

/// The line with its ASCII letters in upper case: `map(text.toUpper)`.
/// Every other byte is left as it is, the bytes of UTF-8 included.
///
/// It is put to a `Line(n)` and answers one. A `[]const u8` has no bytes
/// of its own to write to: copy it into a line first,
/// `compose(.{ Line(32).from, text.toUpper })`.
pub const toUpper = Case("toUpper", .upper);

/// The line with its ASCII letters in lower case: `map(text.toLower)`.
/// See `toUpper`.
pub const toLower = Case("toLower", .lower);

fn Case(comptime who: []const u8, comptime letters: Letters) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Converted(di.types(@TypeOf(args))) {
            // The handler was given the line by value: it is its own to change.
            var line = args[0];
            for (line.bytes[0..line.len]) |*byte| byte.* = switch (letters) {
                .upper => std.ascii.toUpper(byte.*),
                .lower => std.ascii.toLower(byte.*),
            };
            return line;
        }

        fn Converted(comptime Args: []const type) type {
            if (Args.len == 1) {
                if (isLine(Args[0])) return Args[0];
                if (isText(Args[0])) @compileError(
                    who ++ ": a `" ++ @typeName(Args[0]) ++ "` has no bytes of its own to write the result to; copy it into a line first, as in `compose(.{ zrx.Line(32).from, text." ++ who ++ " })`",
                );
            }
            @compileError(who ++ ": is put to one item that is a `zrx.Line(n)`, got " ++ di.listTypes(Args) ++ before(who, ""));
        }
    };
}

// ---------------------------------------------------------------------------
// The pieces of a text, as a source for `each`
// ---------------------------------------------------------------------------

const Division = enum { split, tokenize };

/// A source of the pieces of the item between each `delimiter` and the
/// next, for `each`: `each(text.split(","), sub)` runs `sub` over the
/// columns of every item. A text of `n` delimiters has `n + 1` pieces, the
/// empty ones included; a delimiter of several bytes is that sequence.
///
/// The item is a `[]const u8`, or a struct `T` that reads its text with
/// `pub fn text(*const T) []const u8`, as a `Line` does. A piece is a
/// `[]const u8` that points into the item: for a `[]const u8` into its
/// bytes, for a struct into the struct as `each` holds it while it works on
/// that item. A piece of a struct is valid until the push of that item has
/// returned: through the sub-pipe, `each`'s last emission for the item, and
/// the synchronous stages after the `each`. A caller that keeps a piece
/// longer copies it.
pub fn split(comptime delimiter: []const u8) type {
    if (delimiter.len == 0) @compileError("split: an empty delimiter separates nothing; name what stands between two pieces, as in `text.split(\",\")`");
    return Divide("split", .split, delimiter);
}

/// A source of the pieces of the item that hold none of the bytes in
/// `delimiters`, for `each`: `each(text.tokenize(" \t"), sub)` runs `sub`
/// over the words of every item. Where `split` has an empty piece between
/// two delimiters, this has none: delimiters in a row separate once, and
/// those at either end separate nothing.
///
/// What it is put to and how long a piece lives is as for `split`.
pub fn tokenize(comptime delimiters: []const u8) type {
    if (delimiters.len == 0) @compileError("tokenize: no delimiters; name the bytes that separate two pieces, as in `text.tokenize(\" \\t\")` or `text.tokenize(text.whitespace)`");
    return Divide("tokenize", .tokenize, delimiters);
}

fn Divide(comptime who: []const u8, comptime division: Division, comptime delimiter: []const u8) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        /// The source keeps the item itself, not a slice of it: a handler
        /// is given a value by value, and a slice of that lives no longer
        /// than this call.
        pub fn call(_: anytype, args: anytype) Pieces(Held(di.types(@TypeOf(args))), division, delimiter) {
            return .{ .whole = args[0] };
        }

        /// What the source keeps of the item.
        fn Held(comptime Args: []const type) type {
            if (Args.len == 1) {
                if (isText(Args[0])) return []const u8;
                if (holdsText(Args[0])) return Args[0];
            }
            @compileError(
                who ++ ": is put to one item that is text, a `[]const u8` or a struct `T` with `pub fn text(*const T) []const u8` as a `zrx.Line(n)` is, got " ++ di.listTypes(Args) ++ before(who, "(\",\")"),
            );
        }
    };
}

/// The pieces of one text. `Whole` is a `[]const u8`, or a struct that
/// holds its text.
fn Pieces(comptime Whole: type, comptime division: Division, comptime delimiter: []const u8) type {
    return struct {
        whole: Whole,

        pub const zrx_source = {};
        pub const Item = []const u8;

        pub fn run(self: *const @This(), _: anytype, down: anytype) !void {
            // Read here, where the source stands still for as long as it
            // runs: the pieces point into it.
            const whole: []const u8 = if (comptime Whole == []const u8) self.whole else self.whole.text();
            var pieces = switch (division) {
                .split => if (comptime delimiter.len == 1)
                    std.mem.splitScalar(u8, whole, delimiter[0])
                else
                    std.mem.splitSequence(u8, whole, delimiter),
                .tokenize => if (comptime delimiter.len == 1)
                    std.mem.tokenizeScalar(u8, whole, delimiter[0])
                else
                    std.mem.tokenizeAny(u8, whole, delimiter),
            };
            while (pieces.next()) |piece| {
                if (try down.push(piece) == .done) return;
            }
        }
    };
}
