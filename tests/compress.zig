//! `zrx.ext.compress`: compressed input and output as bindings.
//!
//! Everything is in memory. The known bytes were made by other programs
//! (`gzip`, Python's `zlib`, `zstd`), so decoding them shows more than
//! reading back what this library wrote.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const program = zrx.program;
const lines = zrx.lines;
const range = zrx.range;
const map = zrx.map;
const take = zrx.take;
const fold = zrx.fold;
const print = zrx.print;
const write = zrx.write;
const forEach = zrx.forEach;
const compress = zrx.ext.compress;

/// What a pipe reads and writes: plain text.
const Input = struct { reader: *std.Io.Reader };
const Output = struct { writer: *std.Io.Writer };
/// The compressed bytes, on either side.
const Packed = struct { reader: *std.Io.Reader };
const Archive = struct { writer: *std.Io.Writer };
const Log = struct { writer: *std.Io.Writer };

const words = "alpha\nbeta\ngamma\n";

/// `gzip -9 words.txt`: the header carries a time and the name of the file.
const words_gz =
    "\x1f\x8b\x08\x08\x09\x1b\x02\x6b\x02\x03\x77\x6f\x72\x64\x73\x2e\x74\x78\x74\x00" ++
    "\x4b\xcc\x29\xc8\x48\xe4\x4a\x4a\x2d\x49\xe4\x4a\x4f\xcc\xcd\x4d\xe4\x02\x00\x83" ++
    "\xbb\x9e\xad\x11\x00\x00\x00";
/// Python's `zlib.compress(words, 9)`.
const words_zlib =
    "\x78\xda\x4b\xcc\x29\xc8\x48\xe4\x4a\x4a\x2d\x49\xe4\x4a\x4f\xcc\xcd\x4d\xe4\x02" ++
    "\x00\x36\x87\x05\xc4";
/// `zstd words.txt`: one frame that says how long its content is.
const words_zst =
    "\x28\xb5\x2f\xfd\x24\x11\x89\x00\x00\x61\x6c\x70\x68\x61\x0a\x62\x65\x74\x61\x0a" ++
    "\x67\x61\x6d\x6d\x61\x0a\xb1\x2f\x3e\xed";
/// `zstd < words.txt`: the same content in a frame that asks for a window of 2 MiB.
const piped_zst =
    "\x28\xb5\x2f\xfd\x04\x58\x89\x00\x00\x61\x6c\x70\x68\x61\x0a\x62\x65\x74\x61\x0a" ++
    "\x67\x61\x6d\x6d\x61\x0a\xb1\x2f\x3e\xed";
/// `zstd` of "abcdefghij\n" a hundred thousand times: 1,100,000 bytes, more
/// than a megabyte of window.
const repeated_lines = 100_000;
const repeated_zst =
    "\x28\xb5\x2f\xfd\xa4\xe0\xc8\x10\x00\x9c\x00\x00\x58\x61\x62\x63\x64\x65\x66\x67" ++
    "\x68\x69\x6a\x0a\x01\x00\xf2\xff\xce\x8b\x17\x4c\x00\x00\x08\x68\x01\x00\xfc\xff" ++
    "\x39\x10\x02\x4c\x00\x00\x08\x64\x01\x00\xfc\xff\x39\x10\x02\x4c\x00\x00\x08\x0a" ++
    "\x01\x00\xfc\xff\x39\x10\x02\x4c\x00\x00\x08\x67\x01\x00\xfc\xff\x39\x10\x02\x4c" ++
    "\x00\x00\x08\x63\x01\x00\xfc\xff\x39\x10\x02\x4c\x00\x00\x08\x6a\x01\x00\xfc\xff" ++
    "\x39\x10\x02\x4c\x00\x00\x08\x66\x01\x00\xfc\xff\x39\x10\x02\x4d\x00\x00\x08\x62" ++
    "\x01\x00\xdc\x48\x1d\x08\x01\xb7\x0e\xb8\xc2";
/// Python's `gzip.compress(b"")`: a member with no content.
const empty_gz = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00";

/// What a zstd decoder is given to work in: a block, and a window of 2 MiB,
/// which is what the largest frame here asks for.
const block = std.compress.zstd.block_size_max;
var window: [block + (2 << 20)]u8 = undefined;

/// The one program most tests run. Nothing in it says what its input is.
const listed = program(lines(Input, 8), .{print(Log, "{f},")});

/// What `listed` wrote for `bindings`, which are what stands for its input.
fn listing(buffer: []u8, bindings: anytype) ![]const u8 {
    var log: std.Io.Writer = .fixed(buffer);
    try support.run(listed, bindings ++ .{Log{ .writer = &log }});
    return log.buffered();
}

test "a program reads plain or compressed input, and only its bindings differ" {
    var buffer: [64]u8 = undefined;
    var plain: std.Io.Reader = .fixed(words);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{Input{ .reader = &plain }}));

    var gz: std.Io.Reader = .fixed(words_gz);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ Packed{ .reader = &gz }, compress.gzipReader(Input, Packed, 9) }));

    // The order the bindings are written in decides nothing.
    var zl: std.Io.Reader = .fixed(words_zlib);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ compress.zlibReader(Input, Packed, 9), Packed{ .reader = &zl } }));

    var zs: std.Io.Reader = .fixed(words_zst);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{
        Packed{ .reader = &zs },
        compress.zstdReader(Input, Packed, 9, &window),
    }));
}

test "a decompressing binding is a default like any other, which a plain reader replaces" {
    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    var gz: std.Io.Reader = .fixed(words_gz);
    const from_gzip = listed.provide(.{compress.gzipReader(Input, Packed, 9)});
    try support.run(from_gzip, .{ Packed{ .reader = &gz }, Log{ .writer = &log } });
    try std.testing.expectEqualStrings("alpha,beta,gamma,", log.buffered());

    // Replaced, it is not acquired: nothing provides the `Packed` it needs.
    log = .fixed(&buffer);
    var plain: std.Io.Reader = .fixed("one\n");
    try support.run(from_gzip, .{ Input{ .reader = &plain }, Log{ .writer = &log } });
    try std.testing.expectEqualStrings("one,", log.buffered());
}

test "the roles may be bare readers on one side" {
    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    var gz: std.Io.Reader = .fixed(words_gz);
    const bare = program(lines(*std.Io.Reader, 8), .{print(Log, "{f},")});
    try support.run(bare, .{ Packed{ .reader = &gz }, compress.gzipReader(*std.Io.Reader, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectEqualStrings("alpha,beta,gamma,", log.buffered());

    log = .fixed(&buffer);
    gz = .fixed(words_gz);
    try support.run(listed, .{ &gz, compress.gzipReader(Input, *std.Io.Reader, 9), Log{ .writer = &log } });
    try std.testing.expectEqualStrings("alpha,beta,gamma,", log.buffered());
}

test "the reader of the compressed bytes may have a small buffer, or none" {
    var buffer: [64]u8 = undefined;
    inline for (.{ 0, 1, 3, 4 }) |size| {
        var whole: std.Io.Reader = .fixed(words_gz);
        var small: [size]u8 = undefined;
        var trickle = whole.limited(.unlimited, &small);
        try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ Packed{ .reader = &trickle.interface }, compress.gzipReader(Input, Packed, 9) }));

        whole = .fixed(words_zlib);
        trickle = whole.limited(.unlimited, &small);
        try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ Packed{ .reader = &trickle.interface }, compress.zlibReader(Input, Packed, 9) }));

        whole = .fixed(piped_zst);
        trickle = whole.limited(.unlimited, &small);
        try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{
            Packed{ .reader = &trickle.interface },
            compress.zstdReader(Input, Packed, 9, &window),
        }));
    }
}

test "every member of a gzip stream is read, also one with no content" {
    var buffer: [64]u8 = undefined;
    var members: std.Io.Reader = .fixed(words_gz ++ empty_gz ++ words_gz);
    try std.testing.expectEqualStrings(
        "alpha,beta,gamma,alpha,beta,gamma,",
        try listing(&buffer, .{ Packed{ .reader = &members }, compress.gzipReader(Input, Packed, 9) }),
    );

    var nothing: std.Io.Reader = .fixed(empty_gz);
    try std.testing.expectEqualStrings("", try listing(&buffer, .{ Packed{ .reader = &nothing }, compress.gzipReader(Input, Packed, 9) }));
}

test "every frame of a zstd stream is read" {
    var buffer: [64]u8 = undefined;
    var frames: std.Io.Reader = .fixed(words_zst ++ piped_zst);
    try std.testing.expectEqualStrings("alpha,beta,gamma,alpha,beta,gamma,", try listing(&buffer, .{
        Packed{ .reader = &frames },
        compress.zstdReader(Input, Packed, 9, &window),
    }));
}

/// How `listed` ends when its input is `bytes` in the given format.
fn reading(comptime format: enum { gzip, zlib, zstd }, bytes: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(bytes);
    _ = try switch (format) {
        .gzip => listing(&buffer, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9) }),
        .zlib => listing(&buffer, .{ Packed{ .reader = &reader }, compress.zlibReader(Input, Packed, 9) }),
        .zstd => listing(&buffer, .{ Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 9, &window) }),
    };
}

test "a stream cut short fails the run with ReadFailed, wherever the cut is" {
    inline for (.{
        .{ .gzip, words_gz },
        .{ .zlib, words_zlib },
        .{ .zstd, words_zst },
    }) |case| {
        const format = case[0];
        const whole: []const u8 = case[1];
        try reading(format, whole);
        for (1..whole.len) |kept| {
            try std.testing.expectError(error.ReadFailed, reading(format, whole[0..kept]));
        }
    }
    // Nothing at all is no gzip and no zlib stream. It is a zstd stream
    // of no frames.
    try std.testing.expectError(error.ReadFailed, reading(.gzip, ""));
    try std.testing.expectError(error.ReadFailed, reading(.zlib, ""));
    try reading(.zstd, "");
}

test "ReadFailed is the only error a decompressing binding adds to a run" {
    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    var cut: std.Io.Reader = .fixed(words_gz[0 .. words_gz.len - 1]);
    const left = support.runLeft(listed, .{ Packed{ .reader = &cut }, compress.gzipReader(Input, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectEqual(@as(?anyerror, error.ReadFailed), left.err);
    try std.testing.expectEqualStrings("ReadFailed StreamTooLong WriteFailed ", left.names());

    // The same names as with the plain reader in its place.
    var plain: std.Io.Reader = .fixed("a line too long\n");
    const plainly = support.runLeft(listed, .{ Input{ .reader = &plain }, Log{ .writer = &log } });
    try std.testing.expectEqualStrings("ReadFailed StreamTooLong WriteFailed ", plainly.names());
}

fn with(comptime bytes: []const u8, comptime at: usize, comptime byte: u8) [bytes.len]u8 {
    var changed = bytes[0..bytes.len].*;
    changed[at] = byte;
    return changed;
}

test "content that does not match its checksum or its length fails the read" {
    // `std` reads the trailers and compares nothing: these are the checks
    // of this extension. The last eight bytes of a gzip member are the
    // checksum and the length, the last four of a zlib stream the checksum.
    const wrong_sum = with(words_gz, words_gz.len - 8, words_gz[words_gz.len - 8] ^ 1);
    const wrong_length = with(words_gz, words_gz.len - 4, words_gz[words_gz.len - 4] ^ 1);
    const wrong_adler = with(words_zlib, words_zlib.len - 1, words_zlib[words_zlib.len - 1] ^ 1);
    try std.testing.expectError(error.ReadFailed, reading(.gzip, &wrong_sum));
    try std.testing.expectError(error.ReadFailed, reading(.gzip, &wrong_length));
    try std.testing.expectError(error.ReadFailed, reading(.zlib, &wrong_adler));

    // A second member is checked like the first.
    try std.testing.expectError(error.ReadFailed, reading(.gzip, words_gz ++ wrong_sum));
}

test "bytes after a gzip member or a zstd frame that are neither fail the read" {
    // Both are read to the end of their input, so a read that succeeded
    // has left nothing in the reader it read from.
    try std.testing.expectError(error.ReadFailed, reading(.gzip, words_gz ++ "\x00\x00\x00\x00"));
    try std.testing.expectError(error.ReadFailed, reading(.zstd, words_zst ++ "\x00\x00\x00\x00"));
    try std.testing.expectError(error.ReadFailed, reading(.zstd, words_zst ++ "\x00"));
    // A zlib stream is one stream: what follows it is not read.
    try reading(.zlib, words_zlib ++ "anything");
}

test "what follows a zlib stream is left in the reader it was read from" {
    const follows = "what follows";
    var buffer: [64]u8 = undefined;
    var whole: std.Io.Reader = .fixed(words_zlib ++ follows);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ Packed{ .reader = &whole }, compress.zlibReader(Input, Packed, 9) }));
    try std.testing.expectEqualStrings(follows, whole.buffered());

    // Also in a reader that fills its buffer from somewhere else, where
    // that buffer holds the four bytes `std`'s decoder may ask it to hold.
    whole = .fixed(words_zlib ++ follows);
    var four: [4]u8 = undefined;
    var filled = whole.limited(.unlimited, &four);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", try listing(&buffer, .{ Packed{ .reader = &filled.interface }, compress.zlibReader(Input, Packed, 9) }));
    var rest: [follows.len + 1]u8 = undefined;
    try std.testing.expectEqualStrings(follows, rest[0..try filled.interface.readSliceShort(&rest)]);
}

test "the lines before a failure have been delivered" {
    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    const wrong_sum = with(words_gz, words_gz.len - 8, words_gz[words_gz.len - 8] ^ 1);
    var reader: std.Io.Reader = .fixed(&wrong_sum);
    const result = support.run(listed, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectError(error.ReadFailed, result);
    try std.testing.expectEqualStrings("alpha,beta,gamma,", log.buffered());
}

test "a pipe that is done does not read to the end, and a bad end it never reached is not its failure" {
    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    const wrong_sum = with(words_gz, words_gz.len - 8, words_gz[words_gz.len - 8] ^ 1);
    var reader: std.Io.Reader = .fixed(&wrong_sum);
    const first = program(lines(Input, 8), .{ take(1), print(Log, "{f},") });
    try support.run(first, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectEqualStrings("alpha,", log.buffered());
}

test "a line longer than the buffer is StreamTooLong, as it is for a plain reader" {
    // The decoder's own reader asserts here; the buffer in front of it is
    // why this is an error and not a panic.
    var storage: [512]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const long: [100_000]u8 = @splat('a');
    const texts = [_][]const u8{ "short", &long, "end" };
    const long_line = program(zrx.fromSlice(&texts), .{write(Output, "{s}\n")});
    try support.run(long_line, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });

    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(archive.buffered());
    const result = support.run(listed, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectError(error.StreamTooLong, result);
    try std.testing.expectEqualStrings("short,", log.buffered());
}

const Tally = struct { lines: u64 = 0, bytes: u64 = 0 };

fn tally(sum: Tally, line: zrx.Line(16)) Tally {
    return .{ .lines = sum.lines + 1, .bytes = sum.bytes + line.len };
}

fn keep(found: *Tally, sum: Tally) void {
    found.* = sum;
}

const counted = program(lines(Input, 16), .{
    fold(Tally{}, tally),
    forEach(keep),
});

test "a zstd frame is read through a window of more than a megabyte" {
    var found: Tally = .{};
    var reader: std.Io.Reader = .fixed(repeated_zst);
    try support.run(counted, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, &window) });
    try std.testing.expectEqual(Tally{ .lines = repeated_lines, .bytes = repeated_lines * 10 }, found);
}

test "a zstd frame that asks for more window than the slice leaves beside a block fails the read" {
    // The frame holds 1,100,000 bytes and says so: that is its window.
    var found: Tally = .{};
    var reader: std.Io.Reader = .fixed(repeated_zst);
    const short = compress.zstdReader(Input, Packed, 17, window[0 .. block + 1_100_000 - 1]);
    try std.testing.expectError(error.ReadFailed, support.run(counted, .{ &found, Packed{ .reader = &reader }, short }));

    reader = .fixed(repeated_zst);
    const enough = compress.zstdReader(Input, Packed, 17, window[0 .. block + 1_100_000]);
    try support.run(counted, .{ &found, Packed{ .reader = &reader }, enough });
    try std.testing.expectEqual(@as(u64, repeated_lines), found.lines);
}

fn countLine(found: *Tally, _: zrx.Line(16)) void {
    found.lines += 1;
}

test "a zstd decoder that failed is not asked again for what it would make of the rest" {
    // With this byte changed `std` fails inside a frame, and asked again it
    // would go on from where it stood: more lines than the stream holds
    // came out of it, none of them the stream's.
    const corrupt = with(repeated_zst, 28, repeated_zst[28] ^ 0x80);
    var found: Tally = .{};
    var reader: std.Io.Reader = .fixed(&corrupt);
    const each_line = program(lines(Input, 16), .{forEach(countLine)});
    const result = support.run(each_line, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, &window) });
    try std.testing.expectError(error.ReadFailed, result);
    try std.testing.expect(found.lines < repeated_lines);
}

test "a zstd slice with no room for a window fails the run before anything is read" {
    var found: Tally = .{};
    var reader: std.Io.Reader = .fixed(words_zst);
    inline for (.{ 0, 1, block }) |len| {
        const result = support.run(counted, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, window[0..len]) });
        try std.testing.expectError(error.ZstdWindowTooSmall, result);
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
    }

    // One byte of window is not refused: it is enough for a stream of no frames.
    var nothing: std.Io.Reader = .fixed("");
    try support.run(counted, .{ &found, Packed{ .reader = &nothing }, compress.zstdReader(Input, Packed, 17, window[0 .. block + 1]) });

    // The frame of `words` holds 17 bytes and says so: a window of 17 will do.
    try std.testing.expectError(error.ReadFailed, support.run(counted, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, window[0 .. block + 16]) }));
    reader = .fixed(words_zst);
    try support.run(counted, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, window[0 .. block + 17]) });
    try std.testing.expectEqual(Tally{ .lines = 3, .bytes = 14 }, found);
}

test "a zstd reader asks for no allocator, and adds one error to a run beside ReadFailed" {
    var found: Tally = .{};
    var reader: std.Io.Reader = .fixed(words_zst);
    const left = support.runLeft(counted, .{ &found, Packed{ .reader = &reader }, compress.zstdReader(Input, Packed, 17, window[0..0]) });
    try std.testing.expectEqual(@as(?anyerror, error.ZstdWindowTooSmall), left.err);
    try std.testing.expectEqualStrings("ReadFailed StreamTooLong ZstdWindowTooSmall ", left.names());
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Numbers as lines: enough of them to pass the window of the format many
/// times over, and regular enough to compress.
const numbers = 60_000;
const numbered = program(range(u32, 0, numbers), .{write(Output, "line {d}\n")});

fn expectNumbered(found: Tally) !void {
    var bytes: u64 = 0;
    for (0..numbers) |n| bytes += std.fmt.count("line {d}", .{n});
    try std.testing.expectEqual(Tally{ .lines = numbers, .bytes = bytes }, found);
}

test "what a compressing writer wrote is read back, in gzip and in zlib" {
    const storage = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(storage);

    inline for (.{ .gzip, .zlib }) |format| {
        var archive: std.Io.Writer = .fixed(storage);
        try support.run(numbered, .{ Archive{ .writer = &archive }, switch (format) {
            .gzip => compress.gzipWriter(Output, Archive, .{}),
            .zlib => compress.zlibWriter(Output, Archive, .{}),
            else => unreachable,
        } });
        // It did compress: the plain text is 648,890 bytes.
        try std.testing.expect(archive.buffered().len < 200_000);

        var found: Tally = .{};
        var reader: std.Io.Reader = .fixed(archive.buffered());
        try support.run(counted, .{ &found, Packed{ .reader = &reader }, switch (format) {
            .gzip => compress.gzipReader(Input, Packed, 17),
            .zlib => compress.zlibReader(Input, Packed, 17),
            else => unreachable,
        } });
        try expectNumbered(found);
    }
}

test "a level is the compressor's, and every level reads back" {
    const storage = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(storage);
    var sizes: [2]usize = undefined;
    inline for (.{ compress.WriterOptions{ .level = .fastest }, compress.WriterOptions{ .level = .best } }, &sizes) |options, *size| {
        var archive: std.Io.Writer = .fixed(storage);
        try support.run(numbered, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, options) });
        size.* = archive.buffered().len;

        var found: Tally = .{};
        var reader: std.Io.Reader = .fixed(archive.buffered());
        try support.run(counted, .{ &found, Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 17) });
        try expectNumbered(found);
    }
    // The level reaches the compressor. Which of the two is smaller is
    // `std`'s matter: on this text its fastest level is, by a sixth.
    try std.testing.expect(sizes[0] != sizes[1]);
}

test "a program writes plain or compressed output, and only its bindings differ" {
    const three = program(range(u32, 0, 3), .{write(Output, "{d}\n")});
    var plain_storage: [64]u8 = undefined;
    var plain: std.Io.Writer = .fixed(&plain_storage);
    try support.run(three, .{Output{ .writer = &plain }});
    try std.testing.expectEqualStrings("0\n1\n2\n", plain.buffered());

    var storage: [64]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    try support.run(three, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });
    // A gzip stream: its magic number and the method, deflate.
    try std.testing.expectEqualStrings("\x1f\x8b\x08", archive.buffered()[0..3]);

    var buffer: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(archive.buffered());
    try std.testing.expectEqualStrings("0,1,2,", try listing(&buffer, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9) }));
}

test "print compresses too: a flush of every item ends a block and nothing else" {
    var storage: [128]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const three = program(range(u32, 0, 3), .{print(Output, "{d}\n")});
    try support.run(three, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });

    var buffer: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(archive.buffered());
    try std.testing.expectEqualStrings("0,1,2,", try listing(&buffer, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9) }));
}

test "a run with no items writes a stream of no content" {
    var storage: [64]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const none = program(range(u32, 0, 0), .{write(Output, "{d}\n")});
    try support.run(none, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });

    var buffer: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(archive.buffered());
    try std.testing.expectEqualStrings("", try listing(&buffer, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9) }));
}

/// A writer that keeps what reached it in `flushed` apart from what still
/// sits in its buffer, as a file does.
const Sink = struct {
    flushed: [256]u8 = undefined,
    len: usize = 0,
    writer: std.Io.Writer,

    fn init(buffer: []u8) Sink {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const sink: *Sink = @alignCast(@fieldParentPtr("writer", w));
        sink.add(w.buffered());
        w.end = 0;
        var taken: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            sink.add(bytes);
            taken += bytes.len;
        }
        for (0..splat) |_| sink.add(data[data.len - 1]);
        return taken + splat * data[data.len - 1].len;
    }

    fn add(sink: *Sink, bytes: []const u8) void {
        @memcpy(sink.flushed[sink.len..][0..bytes.len], bytes);
        sink.len += bytes.len;
    }
};

test "the end of the stream is written and flushed into the writer below when the run has succeeded" {
    // Nobody else flushes that writer: a `fileWriter` that replaces a file
    // leaves it to the sink of the pipe, and the sink flushes its own role.
    var buffer: [64]u8 = undefined;
    var sink: Sink = .init(&buffer);
    const three = program(range(u32, 0, 3), .{write(Output, "{d}\n")});
    try support.run(three, .{ Archive{ .writer = &sink.writer }, compress.gzipWriter(Output, Archive, .{}) });
    try std.testing.expectEqual(@as(usize, 0), sink.writer.end);

    var listed_buffer: [64]u8 = undefined;
    var reader: std.Io.Reader = .fixed(sink.flushed[0..sink.len]);
    try std.testing.expectEqualStrings("0,1,2,", try listing(&listed_buffer, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9) }));
}

fn refuseTwo(n: u32) error{Two}!u32 {
    return if (n == 2) error.Two else n;
}

test "a run that failed leaves the stream without its end, and reading it back fails" {
    var storage: [128]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const failing = program(range(u32, 0, 5), .{ map(refuseTwo), print(Output, "{d}\n") });
    const result = support.run(failing, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });
    try std.testing.expectError(error.Two, result);
    // The header and the two items that were flushed are there.
    try std.testing.expect(archive.buffered().len > 10);

    var buffer: [64]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed(archive.buffered());
    const read_back = support.run(listed, .{ Packed{ .reader = &reader }, compress.gzipReader(Input, Packed, 9), Log{ .writer = &log } });
    try std.testing.expectError(error.ReadFailed, read_back);
    try std.testing.expectEqualStrings("0,1,", log.buffered());
}

test "an end that cannot be written fails the run with WriteFailed" {
    // Room for the header and not for what follows.
    var storage: [12]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const three = program(range(u32, 0, 3), .{write(Output, "{d}\n")});
    const result = support.run(three, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });
    try std.testing.expectError(error.WriteFailed, result);
}

test "a writer below with too small a buffer fails the run before anything is written" {
    var storage: [8]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&storage);
    const three = program(range(u32, 0, 3), .{write(Output, "{d}\n")});
    const result = support.run(three, .{ Archive{ .writer = &archive }, compress.gzipWriter(Output, Archive, .{}) });
    try std.testing.expectError(error.CompressedBufferTooSmall, result);
    try std.testing.expectEqual(@as(usize, 0), archive.end);
}

test "compressed output goes through a published file's rules: the end is there before the name is" {
    const io = std.testing.io;
    const path = ".zig-cache/tmp/zrx-compress-published.gz";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const File = struct { reader: *std.Io.Reader };

    const three = program(range(u32, 0, 3), .{write(Output, "{d}\n")});
    try support.run(three, .{
        io,
        compress.gzipWriter(Output, Archive, .{}),
        zrx.fileWriter(Archive, path, 64, .{ .mode = .publish }),
    });

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0,1,2,", try listing(&buffer, .{
        io,
        zrx.fileReader(File, path, 16),
        compress.gzipReader(Input, File, 9),
    }));

    // A failed run names no file.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const failing = program(range(u32, 0, 5), .{ map(refuseTwo), write(Output, "{d}\n") });
    const result = support.run(failing, .{
        io,
        compress.gzipWriter(Output, Archive, .{}),
        zrx.fileWriter(Archive, path, 64, .{ .mode = .publish }),
    });
    try std.testing.expectError(error.Two, result);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}
