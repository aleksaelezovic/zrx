//! `zrx.ext.bytes`: digests of byte pieces, and the text of bytes.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const map = zrx.map;
const fold = zrx.fold;
const each = zrx.each;
const queue = zrx.queue;
const recover = zrx.recover;
const forEach = zrx.forEach;
const print = zrx.print;
const write = zrx.write;
const bytes = zrx.ext.bytes;
const json = zrx.ext.json;

const Out = *std.Io.Writer;
const Piece = []const u8;

const no_pieces = [_]Piece{};
const abc = [_]Piece{ "a", "", "bc" };
const digits = [_]Piece{ "1234", "5", "6789" };

/// Runs `work` over `pieces` and returns what it wrote to its `Out`.
fn written(comptime work: anytype, pieces: []const Piece, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try support.run(program(fromSlice(pieces), work), .{&writer});
    return writer.buffered();
}

// --- digests ------------------------------------------------------------------

const Sha256 = bytes.digest(std.crypto.hash.sha2.Sha256.init(.{}));
const Crc32 = bytes.digest(std.hash.Crc32.init());

const sha256_hex = pipe(.{
    fold(Sha256{}, Sha256.update),
    map(Sha256.final),
    map(bytes.hex(.lower)),
    print(Out, "{s}"),
});

test "a std.crypto digest of no pieces is the digest of nothing" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        try written(sha256_hex, &no_pieces, &buffer),
    );
}

test "a std.crypto digest of several pieces is the digest of their bytes in order" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try written(sha256_hex, &abc, &buffer),
    );
}

/// A `std.hash` digest is the integer its hasher returns: a number, which
/// its format writes.
const crc32_hex = pipe(.{
    fold(Crc32{}, Crc32.update),
    map(Crc32.final),
    print(Out, "{x:0>8}"),
});

test "a std.hash digest of no pieces is the digest of nothing" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("00000000", try written(crc32_hex, &no_pieces, &buffer));
}

test "a std.hash digest of several pieces is the digest of their bytes in order" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("cbf43926", try written(crc32_hex, &digits, &buffer));
}

/// What `fold` and `final` make of `pieces`, for the hasher `start`.
fn digested(comptime start: anytype, pieces: []const Piece) !@TypeOf(bytes.digest(start).final(.{})) {
    const State = bytes.digest(start);
    const Result = @TypeOf(State.final(.{}));
    const Seen = struct {
        result: ?Result = null,

        fn keep(seen: *@This(), result: Result) void {
            seen.result = result;
        }
    };
    var seen: Seen = .{};
    const work = pipe(.{
        fold(State{}, State.update),
        map(State.final),
        forEach(Seen.keep),
    });
    try support.run(program(fromSlice(pieces), work), .{&seen});
    return seen.result.?;
}

test "a hasher is started as its own init starts it, seed and options included" {
    const text = "123456789";
    try std.testing.expectEqual(std.hash.XxHash64.hash(7, text), try digested(std.hash.XxHash64.init(7), &digits));
    try std.testing.expectEqual(std.hash.XxHash3.hash(7, text), try digested(std.hash.XxHash3.init(7), &digits));
    try std.testing.expectEqual(std.hash.Wyhash.hash(7, text), try digested(std.hash.Wyhash.init(7), &digits));
    try std.testing.expectEqual(std.hash.Fnv1a_64.hash(text), try digested(std.hash.Fnv1a_64.init(), &digits));

    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
    var shortened: [Blake2b256.digest_length]u8 = undefined;
    Blake2b256.hash(text, &shortened, .{ .expected_out_bits = 128 });
    try std.testing.expectEqual(shortened, try digested(Blake2b256.init(.{ .expected_out_bits = 128 }), &digits));
}

test "a hasher that fills an output is finished into its digest_length bytes" {
    const text = "123456789";
    const Blake3 = std.crypto.hash.Blake3;
    var blake3: [Blake3.digest_length]u8 = undefined;
    Blake3.hash(text, &blake3, .{});
    try std.testing.expectEqual(blake3, try digested(Blake3.init(.{}), &digits));

    const Shake128 = std.crypto.hash.sha3.Shake128;
    var shake: [Shake128.digest_length]u8 = undefined;
    Shake128.hash(text, &shake, .{});
    try std.testing.expectEqual(shake, try digested(Shake128.init(.{}), &digits));

    const Sha3_256 = std.crypto.hash.sha3.Sha3_256;
    var sha3: [Sha3_256.digest_length]u8 = undefined;
    Sha3_256.hash(text, &sha3, .{});
    try std.testing.expectEqual(sha3, try digested(Sha3_256.init(.{}), &digits));
}

test "a TupleHash is taken, and its digest is of the pieces and not of their bytes" {
    // A TupleHash is started by absorbing its name, at compile time here.
    @setEvalBranchQuota(100_000);
    const TupleHash128 = std.crypto.hash.sha3.TupleHash128;
    var tuple = TupleHash128.init();
    for (digits) |piece| tuple.update(piece);
    var expected: [TupleHash128.digest_length]u8 = undefined;
    tuple.final(&expected);
    const pieces = try digested(TupleHash128.init(), &digits);
    try std.testing.expectEqual(expected, pieces);
    try std.testing.expect(!std.mem.eql(u8, &pieces, &try digested(TupleHash128.init(), &.{"123456789"})));
}

test "the digest is what the hasher's own final returns" {
    // A TupleHash is started by absorbing its name, at compile time here.
    @setEvalBranchQuota(100_000);
    const hash = std.crypto.hash;
    const expect = struct {
        fn result(comptime Result: type, comptime start: anytype) !void {
            try std.testing.expect(Result == @TypeOf(bytes.digest(start).final(.{})));
        }
    }.result;
    try expect([16]u8, hash.Md5.init(.{}));
    try expect([20]u8, hash.Sha1.init(.{}));
    try expect([28]u8, hash.sha2.Sha224.init(.{}));
    try expect([32]u8, hash.sha2.Sha256.init(.{}));
    try expect([48]u8, hash.sha2.Sha384.init(.{}));
    try expect([64]u8, hash.sha2.Sha512.init(.{}));
    try expect([24]u8, hash.sha2.Sha256T192.init(.{}));
    try expect([28]u8, hash.sha2.Sha512T224.init(.{}));
    try expect([32]u8, hash.sha2.Sha512T256.init(.{}));
    try expect([28]u8, hash.sha2.Sha512_224.init(.{}));
    try expect([32]u8, hash.sha2.Sha512_256.init(.{}));
    // Every hasher of `std.crypto.hash.sha3` that the guide names.
    try expect([28]u8, hash.sha3.Sha3_224.init(.{}));
    try expect([32]u8, hash.sha3.Sha3_256.init(.{}));
    try expect([48]u8, hash.sha3.Sha3_384.init(.{}));
    try expect([64]u8, hash.sha3.Sha3_512.init(.{}));
    try expect([32]u8, hash.sha3.Keccak256.init(.{}));
    try expect([64]u8, hash.sha3.Keccak512.init(.{}));
    try expect([32]u8, hash.sha3.Shake128.init(.{}));
    try expect([64]u8, hash.sha3.Shake256.init(.{}));
    try expect([32]u8, hash.sha3.TurboShake128(null).init(.{}));
    try expect([64]u8, hash.sha3.TurboShake256(null).init(.{}));
    try expect([32]u8, hash.sha3.CShake128.init(.{}));
    try expect([64]u8, hash.sha3.CShake256.init(.{}));
    try expect([32]u8, hash.sha3.TupleHash128.init());
    try expect([64]u8, hash.sha3.TupleHash256.init());
    try expect([32]u8, hash.sha3.KT128.init(.{}));
    try expect([64]u8, hash.sha3.KT256.init(.{}));
    try expect([16]u8, hash.blake2.Blake2s128.init(.{}));
    try expect([20]u8, hash.blake2.Blake2s160.init(.{}));
    try expect([28]u8, hash.blake2.Blake2s224.init(.{}));
    try expect([32]u8, hash.blake2.Blake2s256.init(.{}));
    try expect([16]u8, hash.blake2.Blake2b128.init(.{}));
    try expect([20]u8, hash.blake2.Blake2b160.init(.{}));
    try expect([32]u8, hash.blake2.Blake2b256.init(.{}));
    try expect([48]u8, hash.blake2.Blake2b384.init(.{}));
    try expect([64]u8, hash.blake2.Blake2b512.init(.{}));
    try expect([32]u8, hash.Blake3.init(.{}));
    try expect([32]u8, hash.ascon.AsconHash256.init(.{}));
    try expect([32]u8, hash.composition.Sha256oSha256.init(.{}));
    try expect(u32, std.hash.Crc32.init());
    try expect(u32, std.hash.Fnv1a_32.init());
    try expect(u128, std.hash.Fnv1a_128.init());
    try expect(u64, std.hash.Wyhash.init(0));
    try expect(u32, std.hash.XxHash32.init(0));
    try expect(u64, std.hash.XxHash64.init(0));
    try expect(u64, std.hash.XxHash3.init(0));
}

/// A hasher of one's own: the sum of the bytes, and how many there were.
const Sum = struct {
    total: u8 = 0,
    count: u8 = 0,

    pub fn update(sum: *Sum, piece: []const u8) void {
        for (piece) |byte| sum.total +%= byte;
        sum.count +%= @truncate(piece.len);
    }
};

/// Finished into a number, as the hashers of `std.hash` are.
const SumValue = struct {
    sum: Sum = .{},

    pub fn update(hasher: *SumValue, piece: []const u8) void {
        hasher.sum.update(piece);
    }

    pub fn final(hasher: SumValue) u8 {
        return hasher.sum.total;
    }
};

/// Finished into an array it is handed, as some of `std.crypto.hash` are.
const SumFilled = struct {
    sum: Sum = .{},

    pub fn update(hasher: *SumFilled, piece: []const u8) void {
        hasher.sum.update(piece);
    }

    pub fn final(hasher: *SumFilled, out: *[2]u8) void {
        out.* = .{ hasher.sum.total, hasher.sum.count };
    }
};

test "a hasher of one's own is taken by its shape" {
    try std.testing.expectEqual(@as(u8, '1' + '2' + '3'), try digested(SumValue{}, &.{ "1", "23" }));
    try std.testing.expectEqual([2]u8{ '1' + '2' + '3', 3 }, try digested(SumFilled{}, &.{ "1", "23" }));
}

const Pieces = @TypeOf(fromSlice(@as([]const Piece, &.{})));

fn piecesOf(file: []const Piece) Pieces {
    return fromSlice(file);
}

fn describe(writer: Out, file: zrx.Tagged([]const Piece, u32)) !void {
    try writer.print("{d}:{x:0>8};", .{ file.source.len, file.item });
}

test "inside each, every item has a digest of its own" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const files = [_][]const Piece{ &digits, &no_pieces, &digits };
    const checksums = pipe(.{
        each(piecesOf, .{
            fold(Crc32{}, Crc32.update),
            map(Crc32.final),
        }),
        forEach(describe),
    });
    try support.run(program(fromSlice(&files), checksums), .{&writer});
    try std.testing.expectEqualStrings("3:cbf43926;0:00000000;3:cbf43926;", writer.buffered());
}

const Row = struct { pieces: usize, sha256: [64]u8 };

fn row(file: zrx.Tagged([]const Piece, [64]u8)) Row {
    return .{ .pieces = file.source.len, .sha256 = file.item };
}

test "the hexadecimal text of a digest is a value: a field of a row" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const files = [_][]const Piece{ &abc, &no_pieces };
    const manifest = pipe(.{
        each(piecesOf, .{
            fold(Sha256{}, Sha256.update),
            map(Sha256.final),
            map(bytes.hex(.lower)),
        }),
        map(row),
        map(json.encode(.{})),
        write(Out, "{f}\n"),
    });
    try support.run(program(fromSlice(&files), manifest), .{&writer});
    try std.testing.expectEqualStrings(
        \\{"pieces":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
        \\{"pieces":0,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
        \\
    , writer.buffered());
}

/// The state is a value like any other: one of a caller's own can hold it.
const Counted = struct {
    sha: Sha256 = .{},
    bytes: u64 = 0,

    fn update(counted: Counted, piece: Piece) Counted {
        return .{ .sha = Sha256.update(counted.sha, piece), .bytes = counted.bytes + piece.len };
    }

    fn describe(writer: Out, counted: Counted) !void {
        try writer.print("{d} {x}", .{ counted.bytes, Sha256.final(counted.sha) });
    }
};

test "a state of one's own holds a digest and updates it with the reducer" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try written(.{
            fold(Counted{}, Counted.update),
            forEach(Counted.describe),
        }, &abc, &buffer),
    );
}

// --- hex ----------------------------------------------------------------------

fn firstFour(piece: Piece) [4]u8 {
    return piece[0..4].*;
}

test "hex of an array is an array of twice its length, in the case asked for" {
    const words = [_]Piece{ "\x00\xab\xcd\xef", "zrx!" };
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00abcdef;7a727821;", try written(.{
        map(firstFour),
        map(bytes.hex(.lower)),
        print(Out, "{s};"),
    }, &words, &buffer));
    try std.testing.expectEqualStrings("00ABCDEF;7A727821;", try written(.{
        map(firstFour),
        map(bytes.hex(.upper)),
        print(Out, "{s};"),
    }, &words, &buffer));
    try std.testing.expect([8]u8 == zrx.di.Result("test", bytes.hex(.lower), &.{[4]u8}));
}

test "hex of bytes whose length is not known is written with {f}" {
    const words = [_]Piece{ "", "\xff", "zrx" };
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(";ff;7a7278;", try written(.{
        map(bytes.hex(.lower)),
        print(Out, "{f};"),
    }, &words, &buffer));
    try std.testing.expectEqualStrings(";FF;7A7278;", try written(.{
        map(bytes.hex(.upper)),
        print(Out, "{f};"),
    }, &words, &buffer));
}

const Name = zrx.Line(8);

fn named(piece: Piece) !Name {
    return .from(piece);
}

test "the text of a line holds the line: it crosses a queue" {
    const words = [_]Piece{ "zrx", "", "bytes" };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fromSlice(&words), .{
        map(named),
        map(bytes.hex(.lower)),
        queue(2),
        print(Out, "{f};"),
    }), .{ io, &writer });
    try std.testing.expectEqualStrings("7a7278;;6279746573;", writer.buffered());

    writer = .fixed(&buffer);
    try support.run(program(fromSlice(&words), .{
        map(named),
        map(bytes.base64(std.base64.standard)),
        queue(2),
        print(Out, "{f};"),
    }), .{ io, &writer });
    try std.testing.expectEqualStrings("enJ4;;Ynl0ZXM=;", writer.buffered());
}

test "std's own format writes bytes that are printed as they are, piece by piece" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("313233343536373839", try written(.{write(Out, "{x}")}, &digits, &buffer));
    try std.testing.expectEqualStrings("YQ==;;YmM=;", try written(.{write(Out, "{b64};")}, &abc, &buffer));
}

// --- base64 -------------------------------------------------------------------

fn firstTwo(piece: Piece) [2]u8 {
    return piece[0..2].*;
}

test "base64 of an array is an array, padded as its alphabet has it" {
    const words = [_]Piece{ "fo", "\xfb\xff" };
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Zm8=;+/8=;", try written(.{
        map(firstTwo),
        map(bytes.base64(std.base64.standard)),
        print(Out, "{s};"),
    }, &words, &buffer));
    try std.testing.expectEqualStrings("Zm8;-_8;", try written(.{
        map(firstTwo),
        map(bytes.base64(std.base64.url_safe_no_pad)),
        print(Out, "{s};"),
    }, &words, &buffer));
    try std.testing.expect([4]u8 == zrx.di.Result("test", bytes.base64(std.base64.standard), &.{[2]u8}));
    try std.testing.expect([3]u8 == zrx.di.Result("test", bytes.base64(std.base64.url_safe_no_pad), &.{[2]u8}));
}

test "base64 of bytes whose length is not known is written with {f}" {
    // RFC 4648, section 10.
    const words = [_]Piece{ "", "f", "fo", "foo", "foob", "fooba", "foobar" };
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(";Zg==;Zm8=;Zm9v;Zm9vYg==;Zm9vYmE=;Zm9vYmFy;", try written(.{
        map(bytes.base64(std.base64.standard)),
        print(Out, "{f};"),
    }, &words, &buffer));
    try std.testing.expectEqualStrings(";Zg;Zm8;Zm9v;Zm9vYg;Zm9vYmE;Zm9vYmFy;", try written(.{
        map(bytes.base64(std.base64.url_safe_no_pad)),
        print(Out, "{f};"),
    }, &words, &buffer));
}

// --- decoding -----------------------------------------------------------------

const Rejections = struct {
    names: [8][]const u8 = undefined,
    len: usize = 0,

    fn note(rejections: *Rejections, failure: anytype) void {
        rejections.names[rejections.len] = @errorName(failure.err);
        rejections.len += 1;
    }

    fn expect(rejections: *const Rejections, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, rejections.len);
        for (expected, rejections.names[0..rejections.len]) |want, have| try std.testing.expectEqualStrings(want, have);
    }
};

test "fromHex returns the bytes, and names what is wrong with a text" {
    const texts = [_]Piece{ "00abCDef", "7a7278", "7a727821", "7a7278217a", "7a72782g", "" };
    var rejections: Rejections = .{};
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fromSlice(&texts), .{
        recover(bytes.HexError, .{forEach(Rejections.note)}),
        map(bytes.fromHex(4)),
        print(Out, "{x};"),
    }), .{ &writer, &rejections });
    try std.testing.expectEqualStrings("00abcdef;7a727821;", writer.buffered());
    try rejections.expect(&.{ "InvalidLength", "InvalidLength", "InvalidCharacter", "InvalidLength" });
    try std.testing.expect(bytes.HexError![4]u8 == zrx.di.Result("test", bytes.fromHex(4), &.{Piece}));
}

test "fromBase64 returns the bytes, and names what is wrong with a text" {
    const texts = [_]Piece{ "Zm9v", "+/8=", "Zm8=", "Zm9vYg==", "Zm9", "Zm.v", "Zm9=", "" };
    var rejections: Rejections = .{};
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fromSlice(&texts), .{
        recover(bytes.Base64Error, .{forEach(Rejections.note)}),
        map(bytes.fromBase64(std.base64.standard, 3)),
        print(Out, "{x};"),
    }), .{ &writer, &rejections });
    try std.testing.expectEqualStrings("666f6f;", writer.buffered());
    // A text that stands for another number of bytes is of the wrong length,
    // whatever else is wrong with it.
    try rejections.expect(&.{ "InvalidLength", "InvalidLength", "InvalidLength", "InvalidPadding", "InvalidCharacter", "InvalidLength", "InvalidLength" });
    try std.testing.expect(bytes.Base64Error![3]u8 == zrx.di.Result("test", bytes.fromBase64(std.base64.standard, 3), &.{Piece}));
}

test "fromBase64 reads the alphabet it is given" {
    // `-_9` leaves bits over that are not zero.
    const texts = [_]Piece{ "-_8", "+/8", "-_9", "-_8=" };
    var rejections: Rejections = .{};
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fromSlice(&texts), .{
        recover(bytes.Base64Error, .{forEach(Rejections.note)}),
        map(bytes.fromBase64(std.base64.url_safe_no_pad, 2)),
        print(Out, "{x};"),
    }), .{ &writer, &rejections });
    try std.testing.expectEqualStrings("fbff;", writer.buffered());
    try rejections.expect(&.{ "InvalidCharacter", "InvalidPadding", "InvalidLength" });
}

test "what was encoded is decoded again, from an array, a text and a line" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const round_trip = pipe(.{
        fold(Sha256{}, Sha256.update),
        map(Sha256.final),
        map(bytes.base64(std.base64.url_safe)),
        map(bytes.fromBase64(std.base64.url_safe, 32)),
        map(bytes.hex(.upper)),
        map(bytes.fromHex(32)),
        print(Out, "{x}"),
    });
    try support.run(program(fromSlice(&abc), round_trip), .{&writer});
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", writer.buffered());

    writer = .fixed(&buffer);
    const line = try zrx.Line(16).from("7a727821");
    try support.run(program(fromValue(line), .{
        map(bytes.fromHex(4)),
        print(Out, "{s}"),
    }), .{&writer});
    try std.testing.expectEqualStrings("zrx!", writer.buffered());
}
