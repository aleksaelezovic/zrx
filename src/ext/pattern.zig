//! Patterns of text: what a whole text looks like, written as a value, and
//! what to take out of it.
//!
//!     const item_path = seq(.{ "/items/", extract(.id, int(u32)) });
//!
//!     filter(service_name)                              // extracts nothing: a `bool`
//!     map(require(record, error.InvalidRecord))         // `Extracted(record)`, or the error
//!     when(compose(.{ http.Request.path, item_path }), .{ ... })
//!
//! A pattern is a handler, as `gt(80)` is: a predicate on one item that is
//! text, which holds when the pattern describes the whole of it. One that
//! extracts nothing answers `bool`. One with an `extract` in it answers
//! `?Extracted(pattern)`, a predicate that finds a value: `when`, `require`
//! and the last place of `all` take it.
//!
//! The item is a `[]const u8`, or a value that holds its text and reads it
//! with `text()`, as a `Line` does. Text extracted from a `[]const u8`
//! points into it. A value moves, and its text with it, so what is taken
//! out of one is a value too: a number (`int`), or a copy (`as`).
//!
//! Matching goes from left to right and what has matched is not given
//! back. `repeat` takes as much as it can and gives nothing back; `oneOf`
//! takes its first choice that matches, for good. That is the scanner one
//! writes by hand, and it is not a regular expression: what such a scanner
//! cannot match, a pattern cannot either. Where a pattern can be seen never
//! to match for that reason, it does not compile.
//!
//! What did not match has still been read. The next choice of a `oneOf`,
//! and what follows an `optional`, begin where the part that failed began,
//! and inside a `repeat` that is once for every round: a choice that reads
//! far before it fails makes a long text cost the square of its length.
//! Nothing here factors what two choices share; the guide says how to write
//! it once.
//!
//! Nothing here is known to the core: a pattern is a composite handler.
const std = @import("std");
const di = @import("../di.zig");

/// A set of bytes, one bit for each.
const Bytes = u256;

fn only(byte_value: u8) Bytes {
    return @as(Bytes, 1) << byte_value;
}

/// What an `extract` keeps: under which name, as which type, and whether
/// the part it is in may be absent from a text the pattern describes.
/// `borrows`: it is text that points into the item.
const Kept = struct { name: []const u8, Type: type, maybe: bool, borrows: bool };

// A pattern is a `Pattern(Node)`. A node is a type that says how to match:
//
//     match(text, at, out) ?usize   the position after it, or null
//     nullable                      whether it can match without taking a byte
//     first: Bytes                  the bytes it can begin with, when it takes any
//     ends_before: ?Bytes           bytes that cannot follow it, because it took them all
//     width: ?usize                 how many bytes it takes, when that is always the same
//     kept: []const Kept            what it extracts
//
// `out` is a pointer to the struct being extracted into, or `{}` when
// nothing is. A node may also declare `literal` (the text it is), `members`
// (the set it is one byte of), or `Value` with `read` (what it keeps
// instead of text).

/// Marks what this file made. A private type and not a name: a caller's
/// own handler may declare anything.
const Mark = struct {};

fn Pattern(comptime N: type) type {
    return struct {
        pub const zrx_pattern: Mark = .{};
        pub const zrx_handler = {};
        const Node = N;

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        /// Whether the whole of the item is what the pattern describes; with
        /// an `extract` in the pattern, what it extracted.
        pub fn call(_: anytype, args: anytype) Asked(N, di.types(@TypeOf(args))) {
            const text: []const u8 = if (comptime isText(@TypeOf(args[0]))) args[0] else args[0].text();
            // A rule that extracts answers its struct, as each of its levels does.
            if (comptime @hasDecl(N, "Record")) {
                var value: N.Record = undefined;
                const end = N.read(text, 0, &value) orelse return null;
                return if (end == text.len) value else null;
            }
            if (comptime N.kept.len != 0) {
                var out: Struct(N) = undefined;
                inline for (N.kept) |kept| {
                    if (kept.maybe) @field(out, kept.name) = null;
                }
                const end = N.match(text, 0, &out) orelse return null;
                return if (end == text.len) out else null;
            }
            // A pattern of one width describes only a text of that length.
            if (comptime N.width) |width| {
                if (text.len != width) return false;
            }
            const end = N.match(text, 0, {}) orelse return false;
            return end == text.len;
        }
    };
}

fn Answer(comptime N: type) type {
    if (@hasDecl(N, "Record")) return ?N.Record;
    return if (N.kept.len == 0) bool else ?Struct(N);
}

/// Whether nothing is described by `N`: a rule where it holds itself one
/// level too deep, and whatever cannot match without that.
fn isNever(comptime N: type) bool {
    return @hasDecl(N, "never") and N.never;
}

/// Whether `N` can match nothing and still say no: a `from` that fails
/// for the text it was given, in a part that may be empty.
const pattern_refuses = refuses;

fn refuses(comptime N: type) bool {
    return @hasDecl(N, "refuses") and N.refuses;
}

/// Whether `N` matches wherever it is put. That it can match without
/// taking a byte is not enough: what it matched may still be refused.
fn alwaysMatches(comptime N: type) bool {
    return N.nullable and !refuses(N);
}

/// Whether a `T` has a pointer in it, and so may point into the text it
/// was made from.
fn holdsPointer(comptime T: type) bool {
    @setEvalBranchQuota(di.quota);
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional_info| holdsPointer(optional_info.child),
        .array => |array| holdsPointer(array.child),
        .vector => |vector| holdsPointer(vector.child),
        .error_union => |fallible| holdsPointer(fallible.payload),
        .@"struct" => |fields| for (fields.field_types) |Field| {
            if (holdsPointer(Field)) break true;
        } else false,
        .@"union" => |fields| for (fields.field_types) |Field| {
            if (holdsPointer(Field)) break true;
        } else false,
        else => false,
    };
}

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

/// Whether a `T` holds a text of its own and reads it with `text()`, as a
/// `Line` does. Told by name: it is what a caller's own type may declare.
fn holdsText(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "text")) return false;
    const reads = switch (@typeInfo(@TypeOf(T.text))) {
        .@"fn" => |reads| reads,
        else => return false,
    };
    return reads.param_types.len == 1 and reads.param_types[0] == *const T and reads.return_type == []const u8;
}

/// `Answer(N)`, where what the pattern is asked about is one text. Part of
/// the type of `call`, so that it is checked where the pattern is used.
fn Asked(comptime N: type, comptime Args: []const type) type {
    if (Args.len != 1 or !(isText(Args[0]) or holdsText(Args[0]))) @compileError(
        "pattern: tests one item that is text, a `[]const u8` or a `Line`, got " ++ di.listTypes(Args) ++
            "; put the handler that yields the text before it, as in `compose(.{ http.Request.path, pattern })`",
    );
    // What a handler is given of a value is a copy, gone when it returns.
    if (!isText(Args[0])) for (if (@hasDecl(N, "Record")) N.inner else N.kept) |kept| {
        if (!kept.borrows) continue;
        const what = "` is a value that takes its text along; keep ";
        // A value with a pointer in it, a level of a rule, a named choice.
        if (kept.Type != []const u8) @compileError(
            "pattern: what `extract(." ++ kept.name ++ ", ...)` keeps has a pointer or a text in it, which would point into the item, and a `" ++ @typeName(Args[0]) ++
                what ++ "copies, as in `as(Line(32), ...)`",
        );
        @compileError(
            "pattern: `extract(." ++ kept.name ++ ", ...)` keeps text that points into the item, and a `" ++ @typeName(Args[0]) ++
                what ++ "a copy, as in `extract(." ++ kept.name ++ ", as(Line(32), ...))`",
        );
    };
    return Answer(N);
}

fn isPattern(comptime p: anytype) bool {
    if (@TypeOf(p) != type or @typeInfo(p) != .@"struct") return false;
    return @hasDecl(p, "zrx_pattern") and @TypeOf(p.zrx_pattern) == Mark;
}

/// The node of a pattern; a string is the pattern of its text.
fn nodeOf(comptime who: []const u8, comptime p: anytype) type {
    if (isPattern(p)) return p.Node;
    const Given = @TypeOf(p);
    if (isText(Given)) return Literal(who, p);
    @compileError(who ++ ": expected a pattern or a string, got `" ++ (if (Given == type) @typeName(p) else @typeName(Given)) ++ "`");
}

fn nodesOf(comptime who: []const u8, comptime parts: anytype) []const type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(@TypeOf(parts))) @compileError(who ++ ": expected a tuple of patterns `.{ a, b }`, got `" ++ @typeName(@TypeOf(parts)) ++ "`");
    if (parts.len == 0) @compileError(who ++ ": needs at least one pattern");
    var out: []const type = &.{};
    for (parts) |part| out = out ++ &[_]type{nodeOf(who, part)};
    return out;
}

fn maybe(comptime kept: []const Kept) []const Kept {
    var out: []const Kept = &.{};
    for (kept) |one| out = out ++ &[_]Kept{.{ .name = one.name, .Type = one.Type, .maybe = true, .borrows = one.borrows }};
    return out;
}

/// Takes back what a part that did not match in the end had extracted.
fn forget(comptime kept: []const Kept, out: anytype) void {
    if (@TypeOf(out) == void) return;
    inline for (kept) |one| @field(out, one.name) = null;
}

// ---------------------------------------------------------------------------
// Text and bytes
// ---------------------------------------------------------------------------

fn Literal(comptime who: []const u8, comptime text: []const u8) type {
    if (text.len == 0) @compileError(who ++ ": an empty string describes nothing; leave it out");
    return struct {
        pub const literal = text;
        pub const nullable = false;
        pub const first: Bytes = only(text[0]);
        pub const ends_before: ?Bytes = null;
        pub const width: ?usize = text.len;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            // One byte is compared as one, as by hand: `std.mem` would ask
            // first whether the two texts are the same memory.
            if (comptime text.len == 1) return if (at < input.len and input[at] == text[0]) at + 1 else null;
            return if (std.mem.startsWith(u8, input[at..], text)) at + text.len else null;
        }
    };
}

fn Set(comptime bytes: Bytes) type {
    return struct {
        pub const members = bytes;
        pub const nullable = false;
        pub const first: Bytes = bytes;
        pub const ends_before: ?Bytes = null;
        pub const width: ?usize = 1;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            if (at == input.len) return null;
            return if (has(input[at])) at + 1 else null;
        }

        /// As comparisons with the runs of the set, which is what one writes
        /// by hand; a table would be a load for every byte.
        pub fn has(byte_value: u8) bool {
            inline for (comptime runs(bytes)) |run| {
                if (byte_value -% run[0] <= run[1] - run[0]) return true;
            }
            return false;
        }
    };
}

/// The runs of consecutive bytes in `bytes`, each as its first and last.
fn runs(comptime bytes: Bytes) []const [2]u8 {
    @setEvalBranchQuota(di.quota);
    var out: []const [2]u8 = &.{};
    var at: usize = 0;
    while (at < 256) {
        if (bytes & only(@intCast(at)) == 0) {
            at += 1;
            continue;
        }
        const from = at;
        while (at < 256 and bytes & only(@intCast(at)) != 0) at += 1;
        out = out ++ &[_][2]u8{.{ @intCast(from), @intCast(at - 1) }};
    }
    return out;
}

/// A byte as one would write it in a message.
fn shown(comptime byte_value: u8) []const u8 {
    return if (std.ascii.isPrint(byte_value)) std.fmt.comptimePrint("'{c}'", .{byte_value}) else std.fmt.comptimePrint("{d}", .{byte_value});
}

/// One byte, any of those in `bytes`: `set("-_")`.
pub fn set(comptime bytes: []const u8) type {
    if (bytes.len == 0) @compileError("set: needs at least one byte, as in `set(\"-_\")`");
    var all: Bytes = 0;
    for (bytes) |byte_value| all |= only(byte_value);
    return Pattern(Set(all));
}

/// One byte, from `from` to `to`, both included: `between('a', 'f')`.
pub fn between(comptime from: u8, comptime to: u8) type {
    if (from > to) @compileError("between: " ++ shown(from) ++ " comes after " ++ shown(to) ++ "; write the lower byte first");
    var all: Bytes = 0;
    for (from..@as(usize, to) + 1) |byte_value| all |= only(@intCast(byte_value));
    return Pattern(Set(all));
}

/// One byte that is none of those `p` is one of: `except(set("/?"))`.
pub fn except(comptime p: anytype) type {
    const N = nodeOf("except", p);
    if (!@hasDecl(N, "members")) @compileError("except: takes a pattern of one byte, such as `set(\"/?\")` or `digit`");
    if (~N.members == 0) @compileError("except: nothing is left when every byte is excepted");
    return Pattern(Set(~N.members));
}

/// Any one byte.
pub const byte = Pattern(Set(~@as(Bytes, 0)));
/// `0` to `9`.
pub const digit = between('0', '9');
/// `a` to `z`.
pub const lower = between('a', 'z');
/// `A` to `Z`.
pub const upper = between('A', 'Z');
/// A letter of either case.
pub const alpha = oneOf(.{ lower, upper });
/// A letter or a digit.
pub const alnum = oneOf(.{ alpha, digit });

// ---------------------------------------------------------------------------
// Sequence, choice, repetition
// ---------------------------------------------------------------------------

/// Each of `parts`, one after the other. A string among them is its text.
pub fn seq(comptime parts: anytype) type {
    const Ns = nodesOf("seq", parts);
    comptime {
        @setEvalBranchQuota(di.quota);
        for (Ns[0 .. Ns.len - 1], Ns[1..], 2..) |Before, After, place| {
            const taken = Before.ends_before orelse continue;
            // A rule at its deepest level never matches, which is no mistake.
            if (isNever(After)) continue;
            if (!After.nullable and After.first & ~taken == 0) @compileError(std.fmt.comptimePrint(
                "seq: part {d} can never match: the part before it takes every byte it could begin with and gives none back; end that part before such a byte, as `repeat(except(set(\"/\")), .{{}})` ends before a `/`",
                .{place},
            ));
        }
    }
    return Pattern(struct {
        pub const nullable = blk: {
            for (Ns) |N| if (!N.nullable) break :blk false;
            break :blk true;
        };
        pub const first: Bytes = blk: {
            var all: Bytes = 0;
            for (Ns) |N| {
                all |= N.first;
                if (!N.nullable) break;
            }
            break :blk all;
        };
        pub const ends_before: ?Bytes = Ns[Ns.len - 1].ends_before;
        pub const never = blk: {
            for (Ns) |N| if (isNever(N)) break :blk true;
            break :blk false;
        };
        pub const refuses = blk: {
            for (Ns) |N| if (pattern_refuses(N)) break :blk true;
            break :blk false;
        };
        pub const width: ?usize = blk: {
            var sum: usize = 0;
            // Saturating, here and in `repeat`: a width or a bound that
            // does not fit a `usize` is more than any text has.
            for (Ns) |N| sum +|= N.width orelse break :blk null;
            break :blk sum;
        };
        pub const kept: []const Kept = blk: {
            var all: []const Kept = &.{};
            for (Ns) |N| all = all ++ N.kept;
            break :blk all;
        };

        pub fn match(input: []const u8, at: usize, out: anytype) ?usize {
            var end = at;
            inline for (Ns) |N| end = N.match(input, end, out) orelse return null;
            return end;
        }
    });
}

/// What cannot be seen to match: a choice behind one that always matches,
/// or behind one that is its beginning.
fn checkChoices(comptime Ns: []const type) void {
    comptime {
        @setEvalBranchQuota(di.quota);
        for (Ns, 1..) |Early, place| {
            if (alwaysMatches(Early) and place != Ns.len) @compileError(std.fmt.comptimePrint(
                "oneOf: choice {d} can match without taking a byte, so it always matches and the choices after it are never reached; put it last, or wrap the others in `optional(oneOf(.{{ ... }}))`",
                .{place},
            ));
            const early = if (@hasDecl(Early, "literal")) Early.literal else continue;
            for (Ns[place..], place + 1..) |Late, later| {
                const late = if (@hasDecl(Late, "literal")) Late.literal else continue;
                if (std.mem.startsWith(u8, late, early)) @compileError(std.fmt.comptimePrint(
                    "oneOf: choice {d}, \"{s}\", is never reached: choice {d}, \"{s}\", matches first and is taken for good; write the longer one first",
                    .{ later, late, place, early },
                ));
            }
        }
    }
}

/// Whether choices were written with names: `.{ .a = x, .b = y }`.
fn isNamed(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !di.isTuple(T) and @typeInfo(T).@"struct".field_names.len != 0;
}

/// What a named choice holds when it is the one that matched: its value
/// where it is one (`int`, `as`, a level of a rule), a struct of what it
/// extracts where it extracts, and nothing otherwise.
fn Held(comptime N: type) type {
    if (@hasDecl(N, "Value")) return N.Value;
    return if (N.kept.len != 0) Struct(N) else void;
}

/// `oneOf` with names: a value that says which choice matched.
fn Named(comptime choices: anytype) type {
    @setEvalBranchQuota(di.quota);
    const names = @typeInfo(@TypeOf(choices)).@"struct".field_names;
    const Ns: [names.len]type = blk: {
        var all: [names.len]type = undefined;
        for (names, &all) |name, *N| N.* = nodeOf("oneOf", @field(choices, name));
        break :blk all;
    };
    checkChoices(&Ns);
    const Choice = blk: {
        var held: [names.len]type = undefined;
        for (Ns, &held) |N, *H| H.* = Held(N);
        const Tag = std.math.IntFittingRange(0, names.len - 1);
        const Which = @Enum(Tag, .exhaustive, names, &std.simd.iota(Tag, names.len));
        break :blk @Union(.auto, Which, names, &held, &@splat(.{}));
    };
    return struct {
        pub const Value = Choice;
        pub const borrows = blk: {
            for (Ns) |N| {
                if (@hasDecl(N, "Value")) {
                    if (@hasDecl(N, "borrows") and N.borrows) break :blk true;
                } else for (N.kept) |one| {
                    if (one.borrows) break :blk true;
                }
            }
            break :blk false;
        };
        /// Any choice may be the one that matches nothing, since one that
        /// can refuse need not be last; it is certain where one is.
        pub const nullable = blk: {
            for (Ns) |N| if (N.nullable) break :blk true;
            break :blk false;
        };
        pub const refuses = blk: {
            for (Ns) |N| if (alwaysMatches(N)) break :blk false;
            break :blk true;
        };
        pub const never = blk: {
            for (Ns) |N| if (!isNever(N)) break :blk false;
            break :blk true;
        };
        pub const first: Bytes = blk: {
            var all: Bytes = 0;
            for (Ns) |N| all |= N.first;
            break :blk all;
        };
        pub const ends_before: ?Bytes = null;
        pub const width: ?usize = null;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            inline for (Ns) |N| {
                if (N.match(input, at, {})) |end| return end;
            }
            return null;
        }

        pub fn read(input: []const u8, at: usize, value: *Choice) ?usize {
            inline for (names, Ns) |name, N| {
                var held: Held(N) = undefined;
                const matched = if (comptime @hasDecl(N, "Value"))
                    N.read(input, at, &held)
                else if (comptime N.kept.len != 0) end: {
                    inline for (N.kept) |one| {
                        if (one.maybe) @field(held, one.name) = null;
                    }
                    break :end N.match(input, at, &held);
                } else N.match(input, at, {});
                if (matched) |end| {
                    value.* = @unionInit(Choice, name, held);
                    return end;
                }
            }
            return null;
        }
    };
}

/// The first of `choices` that matches. It is taken for good: a later
/// choice is not tried when what follows the `oneOf` then does not match.
///
/// With names, `oneOf(.{ .number = int(u32), .word = as(Name, letters) })`,
/// it says which one matched: extracted, it is a tagged union with a field
/// for each choice, holding what that choice keeps.
pub fn oneOf(comptime choices: anytype) type {
    if (isNamed(@TypeOf(choices))) return Pattern(Named(choices));
    const Ns = nodesOf("oneOf", choices);
    checkChoices(Ns);
    // Choices that are each one byte are one set.
    const bytes: ?Bytes = blk: {
        var all: Bytes = 0;
        for (Ns) |N| all |= if (@hasDecl(N, "members")) N.members else break :blk null;
        break :blk all;
    };
    if (bytes) |all| return Pattern(Set(all));
    return Pattern(struct {
        /// Any choice may be the one that matches nothing, since one that
        /// can refuse need not be last; it is certain where one is.
        pub const nullable = blk: {
            for (Ns) |N| if (N.nullable) break :blk true;
            break :blk false;
        };
        pub const refuses = blk: {
            for (Ns) |N| if (alwaysMatches(N)) break :blk false;
            break :blk true;
        };
        pub const first: Bytes = blk: {
            var all: Bytes = 0;
            for (Ns) |N| all |= N.first;
            break :blk all;
        };
        pub const ends_before: ?Bytes = null;
        pub const width: ?usize = null;
        pub const never = blk: {
            for (Ns) |N| if (!isNever(N)) break :blk false;
            break :blk true;
        };
        pub const kept: []const Kept = blk: {
            var all: []const Kept = &.{};
            for (Ns) |N| all = all ++ maybe(N.kept);
            break :blk all;
        };

        pub fn match(input: []const u8, at: usize, out: anytype) ?usize {
            inline for (Ns) |N| {
                if (N.match(input, at, out)) |end| return end;
                forget(N.kept, out);
            }
            return null;
        }
    });
}

/// How often `repeat` matches its pattern: at least `min` times, and no
/// more than `max` when there is one. Both count rounds, not bytes: a round
/// is as long as the pattern makes it.
pub const Count = struct { min: usize = 0, max: ?usize = null };

/// `p` again and again: as often as it matches, up to `count.max`, and at
/// least `count.min` times. It gives nothing back: `repeat(digit, .{})`
/// followed by a digit never matches.
pub fn repeat(comptime p: anytype, comptime count: Count) type {
    const N = nodeOf("repeat", p);
    if (N.nullable) @compileError("repeat: its pattern can match without taking a byte, so it would never stop; repeat a pattern that takes at least one byte");
    if (N.kept.len != 0) @compileError("repeat: `extract(." ++ N.kept[0].name ++ ", ...)` is inside it and would keep only the last round; put the `extract` around the `repeat`");
    if (count.max) |max| {
        if (max == 0 or max < count.min) @compileError(std.fmt.comptimePrint(
            "repeat: `.max = {d}` leaves no room for `.min = {d}`; `max` is at least 1 and at least `min`",
            .{ max, count.min },
        ));
    }
    return Pattern(struct {
        pub const nullable = count.min == 0;
        pub const never = count.min != 0 and isNever(N);
        pub const first: Bytes = N.first;
        /// Without a maximum, it stops only at a byte its pattern is not.
        pub const ends_before: ?Bytes = if (count.max == null and @hasDecl(N, "members")) N.members else null;
        pub const width: ?usize = if (count.max == count.min) (if (N.width) |each| each *| count.min else null) else null;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            var end = at;
            if (comptime N.width) |each| {
                // Rounds are counted by how far it got, as by hand.
                if (comptime count.max) |max| {
                    while (end - at < max *| each) end = N.match(input, end, {}) orelse break;
                } else {
                    while (true) end = N.match(input, end, {}) orelse break;
                }
                return if (end - at >= count.min *| each) end else null;
            }
            var rounds: usize = 0;
            if (comptime count.max) |max| {
                while (rounds < max) : (rounds += 1) end = N.match(input, end, {}) orelse break;
            } else {
                while (true) : (rounds += 1) end = N.match(input, end, {}) orelse break;
            }
            return if (rounds >= count.min) end else null;
        }
    });
}

/// `p`, or nothing where `p` does not match.
pub fn optional(comptime p: anytype) type {
    const N = nodeOf("optional", p);
    // One that can match nothing and can still refuse is worth making optional.
    if (alwaysMatches(N)) @compileError("optional: its pattern can already match without taking a byte");
    return Pattern(struct {
        pub const nullable = true;
        pub const first: Bytes = N.first;
        pub const ends_before: ?Bytes = null;
        pub const width: ?usize = null;
        pub const kept: []const Kept = maybe(N.kept);

        pub fn match(input: []const u8, at: usize, out: anytype) ?usize {
            if (N.match(input, at, out)) |end| return end;
            forget(N.kept, out);
            return at;
        }
    });
}

// ---------------------------------------------------------------------------
// What a pattern keeps
// ---------------------------------------------------------------------------

/// A decimal number that fits `T`, with a `-` before it when `T` is signed.
/// A number that does not fit does not match. Extracted, it is kept as a
/// `T` and not as text.
pub fn int(comptime T: type) type {
    if (@typeInfo(T) != .int or std.math.maxInt(T) < 10) @compileError("int: expected an integer type that holds at least 10, such as `u32`, got `" ++ @typeName(T) ++ "`");
    const signed = @typeInfo(T).int.signedness == .signed;
    const digits = digit.Node.members;
    return Pattern(struct {
        pub const Value = T;
        pub const nullable = false;
        pub const first: Bytes = digits | if (signed) only('-') else 0;
        /// It takes every digit there is.
        pub const ends_before: ?Bytes = digits;
        pub const width: ?usize = null;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            var unused: T = undefined;
            return read(input, at, &unused);
        }

        /// `match`, with the number left in `value`: one pass over the digits.
        pub fn read(input: []const u8, at: usize, value: *T) ?usize {
            var end = at;
            const negative = signed and end < input.len and input[end] == '-';
            if (negative) end += 1;
            const from = end;
            var number: T = 0;
            while (end < input.len and input[end] -% '0' < 10) : (end += 1) {
                const next = std.math.cast(T, input[end] - '0') orelse return null;
                number = std.math.mul(T, number, 10) catch return null;
                number = (if (negative) std.math.sub(T, number, next) else std.math.add(T, number, next)) catch return null;
            }
            if (end == from) return null;
            value.* = number;
            return end;
        }
    });
}

/// What `T.from` returns for a text: a `T`, or an error where it makes none.
fn Made(comptime T: type) ?type {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => {},
        else => return null,
    }
    if (!@hasDecl(T, "from")) return null;
    const makes = switch (@typeInfo(@TypeOf(T.from))) {
        .@"fn" => |makes| makes,
        else => return null,
    };
    if (makes.param_types.len != 1 or makes.param_types[0] != []const u8) return null;
    const R = makes.return_type orelse return null;
    return if (di.Payload(R) == T) R else null;
}

/// `p`, kept as a `T` and not as text: `T.from(text)` makes it. A `Line(32)`
/// is made so, as a copy of up to 32 bytes; a type of your own with a
/// `from` is too. A text `from` fails for does not match, as a number that
/// does not fit an `int` does not.
///
/// The text `from` is given lives as long as the item, and for a `Line`
/// that is no longer than the handler. A `T` with a pointer anywhere in it
/// is therefore taken to point into that text, whatever its `from` does: it
/// is extracted from a `[]const u8` and refused from a `Line`. A `T` that
/// is to be a value has none.
pub fn as(comptime T: type, comptime p: anytype) type {
    const N = nodeOf("as", p);
    const R = Made(T) orelse @compileError(
        "as: expected a type made from text by `pub fn from(text: []const u8) !T`, such as `zrx.Line(32)`, got `" ++ @typeName(T) ++ "`",
    );
    if (N.kept.len != 0) @compileError("as: `extract(." ++ N.kept[0].name ++ ", ...)` is inside it, where only the `" ++ @typeName(T) ++ "` is kept; extract it from a part of its own");
    return Pattern(struct {
        pub const Value = T;
        /// A `T` with a pointer in it may point into the text it was made of.
        pub const borrows = holdsPointer(T);
        pub const refuses = R != T or pattern_refuses(N);
        pub const nullable = N.nullable;
        pub const never = isNever(N);
        pub const first: Bytes = N.first;
        pub const ends_before: ?Bytes = N.ends_before;
        pub const width: ?usize = N.width;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            var unused: T = undefined;
            return read(input, at, &unused);
        }

        pub fn read(input: []const u8, at: usize, value: *T) ?usize {
            const end = N.match(input, at, {}) orelse return null;
            value.* = if (comptime R == T) T.from(input[at..end]) else T.from(input[at..end]) catch return null;
            return end;
        }
    });
}

/// `p`, with what it matched kept as the field `name` of what the pattern
/// extracts: the matched text, or the value of an `int` or an `as`. The
/// text points into the item.
pub fn extract(comptime name: @EnumLiteral(), comptime p: anytype) type {
    const N = nodeOf("extract", p);
    const typed = @hasDecl(N, "Value");
    return Pattern(struct {
        pub const nullable = N.nullable;
        pub const never = isNever(N);
        pub const refuses = pattern_refuses(N);
        pub const first: Bytes = N.first;
        pub const ends_before: ?Bytes = N.ends_before;
        pub const width: ?usize = N.width;
        pub const kept: []const Kept = N.kept ++ &[_]Kept{.{
            .name = @tagName(name),
            .Type = if (typed) N.Value else []const u8,
            .maybe = false,
            // A value borrows where it has a pointer in it, and a level of
            // a rule or a named choice where something it holds does.
            .borrows = if (typed) @hasDecl(N, "borrows") and N.borrows else true,
        }};

        pub fn match(input: []const u8, at: usize, out: anytype) ?usize {
            if (@TypeOf(out) == void) return N.match(input, at, out);
            if (typed) {
                var value: N.Value = undefined;
                const end = N.read(input, at, &value) orelse return null;
                @field(out, @tagName(name)) = value;
                return end;
            }
            const end = N.match(input, at, out) orelse return null;
            @field(out, @tagName(name)) = input[at..end];
            return end;
        }
    });
}

// ---------------------------------------------------------------------------
// A rule that holds itself
// ---------------------------------------------------------------------------

/// How deep a rule may hold itself: `depth` levels of it, the outermost
/// counted. A text nested deeper does not match.
pub const Nesting = struct { depth: usize = 8 };

/// The rule where it would be one level too deep: it describes nothing.
const Never = struct {
    pub const Value = void;
    pub const never = true;
    pub const nullable = false;
    pub const first: Bytes = 0;
    pub const ends_before: ?Bytes = null;
    pub const width: ?usize = null;
    pub const kept: []const Kept = &.{};

    pub fn match(_: []const u8, _: usize, _: anytype) ?usize {
        return null;
    }

    pub fn read(_: []const u8, _: usize, _: *void) ?usize {
        return null;
    }
};

/// A rule that holds itself: `rule` builds the pattern from `self`, which
/// stands for the rule one level further in.
///
///     fn group(comptime self: type) type {
///         return seq(.{ "(", repeat(oneOf(.{ lower, self }), .{}), ")" });
///     }
///     const nested = recursive(group, .{ .depth = 4 });
///
/// A pattern is a value and cannot contain itself, and nothing here calls
/// itself as deep as a text asks: the rule is built `depth` times, each
/// from the one further in, and the innermost `self` describes nothing. So
/// the depth is written, with a default, and it is not the text's to choose.
///
/// What a level extracts is a struct of its own, and not fields of the
/// pattern around it: `extract(.inner, self)` keeps the level further in as
/// that struct, and `extract(.term, rule)` keeps the outermost. The same
/// names at every level are then no clash, and the struct has a size: at
/// the innermost level the field of `self` is a `?void` that is never there.
/// `Extracted(rule)` is the struct of the outermost level, which the rule
/// answers when a text is put to it alone.
pub fn recursive(comptime rule: anytype, comptime nesting: Nesting) type {
    @setEvalBranchQuota(di.quota);
    const builds = switch (@typeInfo(@TypeOf(rule))) {
        .@"fn" => |builds| builds.param_types.len == 1 and builds.param_types[0] == type and builds.return_type == type,
        else => false,
    };
    if (!builds) @compileError(
        "recursive: expected a function that builds the rule from itself, `fn (comptime self: type) type`, got `" ++ @typeName(@TypeOf(rule)) ++ "`",
    );
    if (nesting.depth == 0) @compileError("recursive: `.depth = 0` leaves no level of the rule; a depth is at least 1");
    const Outermost = Level(rule, nesting.depth);
    if (isNever(Outermost.Node)) @compileError(
        "recursive: the rule has no way to end: whatever it describes holds it again; give it a part without `self`, as in `oneOf(.{ self, lower })`",
    );
    return Outermost;
}

/// `rule` with `depth` levels of itself in it.
fn Level(comptime rule: anytype, comptime depth: usize) type {
    const Body = nodeOf("recursive", rule(if (depth == 1) Pattern(Never) else Level(rule, depth - 1)));
    return Pattern(if (Body.kept.len == 0) Body else Recorded(Body));
}

/// A level of a rule that extracts: what it extracts is kept as one value.
fn Recorded(comptime Body: type) type {
    return struct {
        pub const Value = Struct(Body);
        pub const Record = Value;
        /// What the level extracts, for whoever asks whether it borrows.
        pub const inner = Body.kept;
        pub const borrows = blk: {
            for (Body.kept) |one| if (one.borrows) break :blk true;
            break :blk false;
        };
        pub const never = isNever(Body);
        pub const refuses = pattern_refuses(Body);
        pub const nullable = Body.nullable;
        pub const first: Bytes = Body.first;
        pub const ends_before: ?Bytes = Body.ends_before;
        pub const width: ?usize = Body.width;
        pub const kept: []const Kept = &.{};

        pub fn match(input: []const u8, at: usize, _: anytype) ?usize {
            return Body.match(input, at, {});
        }

        pub fn read(input: []const u8, at: usize, value: *Value) ?usize {
            inline for (Body.kept) |one| {
                if (one.maybe) @field(value, one.name) = null;
            }
            return Body.match(input, at, value);
        }
    };
}

/// What `p` extracts, as a struct: a field for each `extract` in it, of the
/// type of what that keeps (`[]const u8`, or the `T` of an `int(T)` or an
/// `as(T, ...)`), and
/// optional where the `extract` is inside `optional` or `oneOf`. A handler
/// that names its item writes `Extracted(p)`; `anytype` takes it too.
pub fn Extracted(comptime p: anytype) type {
    const N = nodeOf("Extracted", p);
    if (@hasDecl(N, "Record")) return N.Record;
    if (N.kept.len == 0) @compileError("Extracted: the pattern extracts nothing; wrap the parts to keep in `extract(.name, ...)`");
    return Struct(N);
}

fn Struct(comptime N: type) type {
    @setEvalBranchQuota(di.quota);
    var names: [N.kept.len][]const u8 = undefined;
    var types: [N.kept.len]type = undefined;
    for (N.kept, 0..) |kept, i| {
        for (N.kept[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, kept.name)) @compileError("extract: `." ++ kept.name ++ "` is extracted twice in one pattern; give each `extract` a name of its own");
        }
        names[i] = kept.name;
        types[i] = if (kept.maybe) ?kept.Type else kept.Type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}
