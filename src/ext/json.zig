//! JSON text for the items of a pipe, and items from JSON text, on top of
//! `std.json`.
//!
//!     const archive = pipe(.{
//!         map(json.decode(Record, .{ .scratch = 256 })),
//!         map(json.encode(.{})),
//!         write(Archive, "{f}\n"),
//!     });
//!
//! Nothing here is known to the core: `encode` and `decode` are handlers
//! like any other.
const std = @import("std");
const di = @import("../di.zig");

/// A handler that maps an item to its JSON text: `map(json.encode(.{}))`.
/// The result is a `std.json.Formatter` holding a copy of the item; write
/// it with `{f}`, as in `write(Role, "{f}\n")` for JSON lines. `options`
/// are those of `std.json.Stringify`, for example
/// `.{ .emit_null_optional_fields = false }`.
pub fn encode(comptime options: std.json.Stringify.Options) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) std.json.Formatter(@TypeOf(args[0])) {
            return std.json.fmt(args[0], options);
        }
    };
}

/// How `decode` reads a text.
pub const DecodeOptions = struct {
    /// How many bytes of memory on the stack `std.json` may use while it
    /// reads one text. A text that needs more fails with
    /// `error.OutOfMemory`. It holds a bit for each level of nesting, in a
    /// list that begins at about a cache line, and a copy of each text that
    /// is written with an escape or as an array of numbers.
    scratch: usize,
    /// `std.json`'s own, for example `.{ .ignore_unknown_fields = true }`.
    parse: std.json.ParseOptions = .{},
};

/// What `decode` fails with: the errors of `std.json` reading one whole
/// text, written out so that an error path can name them.
pub const DecodeError = error{
    SyntaxError,
    UnexpectedEndOfInput,
    UnexpectedToken,
    InvalidNumber,
    InvalidCharacter,
    Overflow,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    ValueTooLong,
    OutOfMemory,
};

/// A handler that maps a text to the `T` it is the JSON of:
/// `map(json.decode(T, .{ .scratch = 256 }))`. The text is the item, a
/// `[]const u8` or a value that reads its text with `text()`, as a `Line`
/// does, and it is one whole document. `options.parse` are those of
/// `std.json.parseFromSlice`.
///
/// What is decoded is a value. `std.json` reads with `options.scratch`
/// bytes on the stack, which are gone when the handler returns, as the
/// text of a `Line` is. A `T` with a pointer anywhere in it would point
/// into one or the other and does not compile: text is kept as a copy, a
/// `zrx.Line(n)`, and several values as an array.
pub fn decode(comptime T: type, comptime options: DecodeOptions) type {
    comptime expectValue(T);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Decoded(T, di.types(@TypeOf(args))) {
            const text: []const u8 = if (comptime isText(@TypeOf(args[0]))) args[0] else args[0].text();
            var scratch: [options.scratch]u8 = undefined;
            var fixed: std.heap.FixedBufferAllocator = .init(&scratch);
            return std.json.parseFromSliceLeaky(T, fixed.allocator(), text, options.parse) catch |err| switch (err) {
                // `std.json` lists it and says a whole text never fails so.
                error.BufferUnderrun => unreachable,
                else => |left| left,
            };
        }
    };
}

/// `DecodeError!T`, where what is decoded is one text. Part of the type of
/// `call`, so that it is checked where the handler is used.
fn Decoded(comptime T: type, comptime Args: []const type) type {
    if (Args.len != 1 or !(isText(Args[0]) or holdsText(Args[0]))) @compileError(
        "json.decode: decodes one item that is text, a `[]const u8` or a `Line`, got " ++ di.listTypes(Args) ++
            "; put the handler that yields the text before it, as in `compose(.{ field(.body), json.decode(T, options) })`",
    );
    return DecodeError!T;
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

/// A place in a type: the type found there and the fields that lead to it.
const Place = struct { Type: type, path: []const u8 };

fn describe(comptime T: type, comptime place: Place) []const u8 {
    if (place.path.len == 0) return "`" ++ @typeName(T) ++ "`";
    return "`" ++ place.path ++ ": " ++ @typeName(place.Type) ++ "` in `" ++ @typeName(T) ++ "`";
}

fn within(comptime path: []const u8, comptime name: []const u8) []const u8 {
    return if (path.len == 0) name else path ++ "." ++ name;
}

/// What `T` is made of, one level down, with where each part is. Every
/// kind of type is written out: one that is passed over here is one whose
/// pointers `decode` does not see, so a kind `std` adds does not compile
/// until it is said what it is made of.
fn parts(comptime T: type, comptime path: []const u8) []const Place {
    return switch (@typeInfo(T)) {
        .optional => |optional| &.{.{ .Type = optional.child, .path = path }},
        .error_union => |fallible| &.{.{ .Type = fallible.payload, .path = path }},
        .array => |array| &.{.{ .Type = array.child, .path = path }},
        .vector => |vector| &.{.{ .Type = vector.child, .path = path }},
        inline .@"struct", .@"union" => |fields| {
            var places: [fields.field_names.len]Place = undefined;
            for (fields.field_names, fields.field_types, &places) |name, Field, *place| {
                place.* = .{ .Type = Field, .path = within(path, name) };
            }
            const found = places;
            return &found;
        },
        // A pointer is not made of what it points to, and is found as itself.
        .pointer,
        .type,
        .void,
        .bool,
        .noreturn,
        .int,
        .float,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .error_set,
        .@"enum",
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .enum_literal,
        .spirv,
        => &.{},
    };
}

/// The first pointer in a `T`, which may point into the text it was read
/// from or into the scratch memory, whatever read it.
fn pointerIn(comptime T: type, comptime path: []const u8) ?Place {
    if (@typeInfo(T) == .pointer) return .{ .Type = T, .path = path };
    for (parts(T, path)) |part| {
        if (pointerIn(part.Type, part.path)) |place| return place;
    }
    return null;
}

/// The first thing in a `T` that `std.json` has no way to read. A type
/// that reads itself with a `jsonParse` is taken at its word.
fn unreadableIn(comptime T: type, comptime path: []const u8) ?Place {
    const here: Place = .{ .Type = T, .path = path };
    switch (@typeInfo(T)) {
        .bool, .int, .float, .optional, .array, .vector => {},
        .@"enum" => return null,
        .@"struct" => |info| {
            if (!info.is_tuple and std.meta.hasFn(T, "jsonParse")) return null;
            for (info.field_attrs) |attrs| if (attrs.@"comptime") return here;
        },
        .@"union" => |info| {
            if (std.meta.hasFn(T, "jsonParse")) return null;
            if (info.tag_type == null) return here;
            // A choice that holds nothing is written `{}`.
            for (parts(T, path)) |part| {
                if (part.Type == void) continue;
                if (unreadableIn(part.Type, part.path)) |place| return place;
            }
            return null;
        },
        else => return here,
    }
    for (parts(T, path)) |part| {
        if (unreadableIn(part.Type, part.path)) |place| return place;
    }
    return null;
}

/// A `T` that `decode` can return: a value, and one `std.json` reads.
fn expectValue(comptime T: type) void {
    @setEvalBranchQuota(di.quota);
    if (pointerIn(T, "")) |place| @compileError(
        "json.decode: " ++ describe(T, place) ++ " would point into the text or into the scratch memory, both gone when the handler returns, and what is decoded is a value; keep text as a copy, as in `zrx.Line(64)`, and several values as an array",
    );
    if (unreadableIn(T, "")) |place| @compileError(
        "json.decode: `std.json` has no way to read " ++ describe(T, place) ++ "; it reads a bool, a number, an enum, an optional, an array, a struct, a `union(enum)`, and a type that declares `jsonParse`",
    );
}
