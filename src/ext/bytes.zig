//! What a stream of byte pieces is turned into: a digest, and the text of
//! bytes. On top of `std.crypto.hash`, `std.hash`, `std.fmt` and
//! `std.base64`.
//!
//!     const Sha256 = bytes.digest(std.crypto.hash.sha2.Sha256.init(.{}));
//!
//!     const checksum = pipe(.{
//!         fold(Sha256{}, Sha256.update),
//!         map(Sha256.final),
//!         map(bytes.hex(.lower)),
//!     });
//!
//! Nothing here is known to the core: these are handlers like any other.
//! There are no ciphers, signatures or keys here, and nothing compares in
//! constant time.
const std = @import("std");
const di = @import("../di.zig");

// --- digests ------------------------------------------------------------------

/// The state of a `fold` over the pieces of some bytes, for the hasher
/// `start` is: `fold(Sha256{}, Sha256.update)` and then `map(Sha256.final)`,
/// where `Sha256` is `digest(std.crypto.hash.sha2.Sha256.init(.{}))`.
///
/// `start` is the hasher as its own `init` starts it, with whatever that
/// takes: options, a seed, nothing. A hasher is told by its shape, the
/// `update` and `final` that those of `std.crypto.hash` and `std.hash` have,
/// and `final` returns what the hasher's own returns or fills: an unsigned
/// integer or an array of bytes.
pub fn digest(comptime start: anytype) type {
    const H = @TypeOf(start);
    const finish = comptime Finish.of(H);
    return struct {
        hasher: H = start,

        const State = @This();

        /// The reducer: the state after `piece`.
        pub fn update(state: State, piece: []const u8) State {
            var next = state;
            next.hasher.update(piece);
            return next;
        }

        /// The digest of the pieces the state was given.
        pub fn final(state: State) finish.Result {
            var hasher = state.hasher;
            switch (comptime finish.how) {
                .value => return hasher.final(),
                .filled => {
                    var out: finish.Result = undefined;
                    hasher.final(&out);
                    return out;
                },
            }
        }
    };
}

/// How a hasher of type `H` hands out its digest, read off its shape.
const Finish = struct {
    how: enum {
        /// `final(*H) T` or `final(H) T`, where `T` is an unsigned integer:
        /// `std.hash`.
        value,
        /// `final(*H, out)`, where `out` is an array to fill, or a slice
        /// that is given `digest_length` bytes: `std.crypto.hash`.
        filled,
    },
    Result: type,

    fn of(comptime H: type) Finish {
        @setEvalBranchQuota(di.quota);
        if (H == type) @compileError(
            "bytes.digest: expected a hasher as it starts, such as `Sha256.init(.{})`, got a type; " ++
                "a hasher is started by its own `init`, with the options or the seed that takes",
        );
        const shaped = switch (@typeInfo(H)) {
            .@"struct" => fed(H),
            else => false,
        };
        if (shaped) {
            if (finished(H)) |finish| return finish;
        }
        @compileError(
            "bytes.digest: `" ++ @typeName(H) ++ "` is not a hasher that is fed and then finished: it needs `update(*H, []const u8) void` and a `final` " ++
                "that returns the digest, an unsigned integer, or fills an array of bytes with it, as the hashers of `std.hash` and `std.crypto.hash` have",
        );
    }

    /// How the `final` of an `H` hands out the digest, or null where it is
    /// neither of the two ways. What is a digest is said here and nowhere
    /// else: an unsigned integer that is returned, or an array of bytes that
    /// is filled. A `bool`, a signed number, an optional and an error union
    /// are none, and neither is a `final` that both fills and returns.
    fn finished(comptime H: type) ?Finish {
        const info = method(H, "final") orelse return null;
        if (info.param_types.len == 0 or !receives(H, info.param_types[0])) return null;
        const Returned = info.return_type orelse return null;
        switch (info.param_types.len) {
            1 => if (isUnsigned(Returned)) return .{ .how = .value, .Result = Returned },
            2 => if (Returned == void) {
                if (Filled(H, info.param_types[1])) |Result| return .{ .how = .filled, .Result = Result };
            },
            else => {},
        }
        return null;
    }

    /// Whether an `H` takes bytes with `update(*H, bytes)` and returns
    /// nothing: the reducer has nowhere to put an answer or a failure.
    fn fed(comptime H: type) bool {
        const info = method(H, "update") orelse return false;
        if (info.param_types.len != 2 or info.param_types[0] != *H) return false;
        if ((info.return_type orelse return false) != void) return false;
        // `anytype` where the hasher takes any list of bytes, as xxHash does.
        const Piece = info.param_types[1] orelse return true;
        return Piece == []const u8;
    }

    /// Whether `final` is a method of `H`: its first parameter is the hasher
    /// or a pointer to it.
    fn receives(comptime H: type, comptime Receiver: ?type) bool {
        const R = Receiver orelse return false;
        return R == H or R == *H or R == *const H;
    }

    fn isUnsigned(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .int => |int| int.signedness == .unsigned,
            else => false,
        };
    }

    /// The array a `final(*H, out)` fills: what `out` points to, or
    /// `digest_length` bytes where it is a slice of any length.
    fn Filled(comptime H: type, comptime Out: ?type) ?type {
        const pointer = switch (@typeInfo(Out orelse return null)) {
            .pointer => |pointer| pointer,
            else => return null,
        };
        if (pointer.attrs.@"const") return null;
        switch (pointer.size) {
            .one => return if (isBytes(pointer.child)) pointer.child else null,
            .slice => {
                if (pointer.child != u8 or !@hasDecl(H, "digest_length")) return null;
                return [H.digest_length]u8;
            },
            else => return null,
        }
    }

    fn method(comptime H: type, comptime name: []const u8) ?std.builtin.Type.Fn {
        if (!@hasDecl(H, name)) return null;
        return switch (@typeInfo(@TypeOf(@field(H, name)))) {
            .@"fn" => |info| info,
            else => null,
        };
    }

    fn isBytes(comptime T: ?type) bool {
        return switch (@typeInfo(T orelse return false)) {
            .array => |array| array.child == u8,
            else => false,
        };
    }
};

// --- the text of bytes --------------------------------------------------------

/// A handler that maps bytes to their hexadecimal digits:
/// `map(hex(.lower))`. An array becomes an array of twice its length, a
/// value. An item whose length is known only when the program runs, a
/// `[]const u8` or a `Line`, becomes a value that holds the item and is
/// written with `{f}`, as in `write(Role, "{f}\n")`.
pub fn hex(comptime case: std.fmt.Case) type {
    return Encode("bytes.hex", struct {
        fn size(comptime len: usize) usize {
            return 2 * len;
        }
        fn array(comptime len: usize, input: *const [len]u8) [2 * len]u8 {
            return std.fmt.bytesToHex(input, case);
        }
        fn print(writer: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
            return writer.printHex(input, case);
        }
    });
}

/// A handler that maps bytes to their Base64 text:
/// `map(base64(std.base64.standard))`. `codecs` is one of `std.base64`:
/// `standard`, `standard_no_pad`, `url_safe`, `url_safe_no_pad`, or one of
/// your own alphabet. What an item becomes is what `hex` makes of it: an
/// array for an array, a value to write with `{f}` otherwise.
pub fn base64(comptime codecs: std.base64.Codecs) type {
    return Encode("bytes.base64", struct {
        fn size(comptime len: usize) usize {
            return codecs.Encoder.calcSize(len);
        }
        fn array(comptime len: usize, input: *const [len]u8) [size(len)]u8 {
            var out: [size(len)]u8 = undefined;
            _ = codecs.Encoder.encode(&out, input);
            return out;
        }
        fn print(writer: *std.Io.Writer, input: []const u8) std.Io.Writer.Error!void {
            return codecs.Encoder.encodeWriter(writer, input);
        }
    });
}

fn Encode(comptime who: []const u8, comptime encoding: type) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Encoded(who, encoding, di.types(@TypeOf(args))) {
            const Item = @TypeOf(args[0]);
            if (comptime shapeOf(Item).? == .array) return encoding.array(@typeInfo(Item).array.len, &args[0]);
            return .{ .item = args[0] };
        }
    };
}

/// What an encoding makes of one item. Part of the type of `call`, so that
/// the item is checked where the handler is used.
fn Encoded(comptime who: []const u8, comptime encoding: type, comptime Args: []const type) type {
    const shape = Asked(who, "encodes one item that is bytes, a `[n]u8`, a `[]const u8` or a `Line`", Args);
    const Item = Args[0];
    if (shape == .array) return [encoding.size(@typeInfo(Item).array.len)]u8;
    return struct {
        /// The bytes, or what holds them.
        item: Item,

        pub fn format(text: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return encoding.print(writer, bytesOf(&text.item));
        }
    };
}

/// What `fromHex` fails with: the text is not as long as the bytes asked
/// for need, or holds something that is no hexadecimal digit.
pub const HexError = error{ InvalidLength, InvalidCharacter };

/// What `fromBase64` fails with: the text does not stand for as many bytes
/// as were asked for, holds a character that is not of the alphabet, or is
/// not padded as its alphabet has it.
pub const Base64Error = error{ InvalidLength, InvalidCharacter, InvalidPadding };

/// A handler that maps hexadecimal digits, of either case, to the `len`
/// bytes they stand for: `map(fromHex(32))` returns a `[32]u8`, a value.
/// A text that is not `2 * len` digits fails with a `HexError`.
pub fn fromHex(comptime len: usize) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Decoded("bytes.fromHex", HexError, len, 2 * len, "hexadecimal digits", di.types(@TypeOf(args))) {
            const text = bytesOf(&args[0]);
            if (text.len != 2 * len) return error.InvalidLength;
            var out: [len]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, text) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidCharacter,
                // The length was looked at above.
                error.InvalidLength, error.NoSpaceLeft => unreachable,
            };
            return out;
        }
    };
}

/// A handler that maps Base64 text to the `len` bytes it stands for:
/// `map(fromBase64(std.base64.standard, 32))` returns a `[32]u8`, a value.
/// A text that does not stand for exactly `len` bytes in the alphabet of
/// `codecs` fails with a `Base64Error`.
pub fn fromBase64(comptime codecs: std.base64.Codecs, comptime len: usize) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Decoded("bytes.fromBase64", Base64Error, len, codecs.Encoder.calcSize(len), "characters of this alphabet", di.types(@TypeOf(args))) {
            const text = bytesOf(&args[0]);
            const size = codecs.Decoder.calcSizeForSlice(text) catch return error.InvalidPadding;
            if (size != len) return error.InvalidLength;
            var out: [len]u8 = undefined;
            codecs.Decoder.decode(&out, text) catch |err| switch (err) {
                error.InvalidCharacter => return error.InvalidCharacter,
                error.InvalidPadding => return error.InvalidPadding,
                // `out` has the size the decoder asked for.
                error.NoSpaceLeft => unreachable,
            };
            return out;
        }
    };
}

/// `E![len]u8`, where what is decoded is one text. An array holds text of a
/// length known here, so one that can never be `len` bytes is refused here.
fn Decoded(
    comptime who: []const u8,
    comptime E: type,
    comptime len: usize,
    comptime text_len: usize,
    comptime units: []const u8,
    comptime Args: []const type,
) type {
    if (Asked(who, "decodes one item that is text, a `[]const u8`, a `Line` or a `[n]u8`", Args) == .array) {
        const have = @typeInfo(Args[0]).array.len;
        if (have != text_len) @compileError(std.fmt.comptimePrint(
            "{s}: {d} bytes are {d} {s}, and the item is a `{s}`, which can never be that; pass the number of bytes its text stands for",
            .{ who, len, text_len, units, @typeName(Args[0]) },
        ));
    }
    return E![len]u8;
}

// --- items that are bytes -----------------------------------------------------

const Shape = enum {
    /// `[n]u8`: the bytes, with a length known at compile time.
    array,
    /// `[]const u8`, or a pointer to an array: bytes that are elsewhere.
    slice,
    /// A value that holds its bytes and reads them with `text()`, as a `Line` does.
    holder,
};

fn shapeOf(comptime T: type) ?Shape {
    switch (@typeInfo(T)) {
        .array => |array| return if (array.child == u8) .array else null,
        .pointer => |pointer| switch (pointer.size) {
            .slice => return if (pointer.child == u8) .slice else null,
            .one => return switch (@typeInfo(pointer.child)) {
                .array => |array| if (array.child == u8) .slice else null,
                else => null,
            },
            else => return null,
        },
        .@"struct" => {
            // Told by name: it is what a caller's own type may declare.
            if (!@hasDecl(T, "text")) return null;
            const reads = switch (@typeInfo(@TypeOf(T.text))) {
                .@"fn" => |reads| reads,
                else => return null,
            };
            if (reads.param_types.len != 1 or reads.param_types[0] != *const T or reads.return_type != []const u8) return null;
            return .holder;
        },
        else => return null,
    }
}

/// The shape of the one item a handler of this extension is asked about.
fn Asked(comptime who: []const u8, comptime does: []const u8, comptime Args: []const type) Shape {
    if (Args.len == 1) if (shapeOf(Args[0])) |shape| return shape;
    const number = Args.len == 1 and @typeInfo(Args[0]) == .int and std.mem.eql(u8, who, "bytes.hex");
    @compileError(
        who ++ ": " ++ does ++ ", got " ++ di.listTypes(Args) ++
            if (number) "; a number is written in hexadecimal by its format, as in `print(Role, \"{x:0>8}\")`" else "",
    );
}

/// The bytes of `item.*`, read where the item is.
fn bytesOf(item: anytype) []const u8 {
    return switch (comptime shapeOf(@TypeOf(item.*)).?) {
        .array => item,
        .slice => item.*,
        .holder => item.text(),
    };
}
