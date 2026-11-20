//! Byte and line I/O.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const range = zrx.range;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const branch = zrx.branch;
const print = zrx.print;
const write = zrx.write;
const lines = zrx.lines;
const fileLines = zrx.fileLines;
const fileBytes = zrx.fileBytes;
const fold = zrx.fold;
const each = zrx.each;
const attempt = zrx.attempt;
const concurrent = zrx.concurrent;
const forEach = zrx.forEach;
const fileWriter = zrx.fileWriter;
const fileReader = zrx.fileReader;
const fromProducer = zrx.fromProducer;
const queue = zrx.queue;
const recover = zrx.recover;

const Report = struct { writer: *std.Io.Writer };
const Log = struct { writer: *std.Io.Writer };
const Input = struct { reader: *std.Io.Reader };

test "print formats every item to the writer it is given" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(range(u32, 1, 4), pipe(.{print(*std.Io.Writer, "{d};")})), .{&writer});
    try std.testing.expectEqualStrings("1;2;3;", writer.buffered());
}

const Entry = struct { name: []const u8, score: u32 };
fn fields(entry: Entry) struct { []const u8, u32 } {
    return .{ entry.name, entry.score };
}

fn failFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {
    return error.WriteFailed;
}

test "print reports flush errors during a push and at stream end" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var vtable = writer.vtable.*;
    vtable.flush = failFlush;
    writer.vtable = &vtable;
    const output = pipe(.{print(*std.Io.Writer, "{d}")});
    try std.testing.expectError(error.WriteFailed, support.run(program(range(u32, 0, 1), output), .{&writer}));
    try std.testing.expectEqualStrings("0", writer.buffered());
    try std.testing.expectError(error.WriteFailed, support.run(program(range(u32, 0, 0), output), .{&writer}));
}

test "a tuple item supplies several format arguments" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const entries = [_]Entry{ .{ .name = "ada", .score = 3 }, .{ .name = "bob", .score = 5 } };
    try support.run(program(fromSlice(&entries), pipe(.{ map(fields), print(Report, "{s}={d}\n") })), .{Report{ .writer = &writer }});
    try std.testing.expectEqualStrings("ada=3\nbob=5\n", writer.buffered());
}

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

test "roles keep two writers apart" {
    var report_bytes: [64]u8 = undefined;
    var log_bytes: [64]u8 = undefined;
    var report: std.Io.Writer = .fixed(&report_bytes);
    var log: std.Io.Writer = .fixed(&log_bytes);
    const work = pipe(.{branch(.{
        pipe(.{ filter(isEven), print(Report, "{d} ") }),
        pipe(.{print(Log, "saw {d}\n")}),
    })});
    try support.run(program(range(u32, 1, 4), work), .{ Report{ .writer = &report }, Log{ .writer = &log } });
    try std.testing.expectEqualStrings("2 ", report.buffered());
    try std.testing.expectEqualStrings("saw 1\nsaw 2\nsaw 3\n", log.buffered());
}

fn nonEmpty(line: zrx.Line(8)) bool {
    return line.len != 0;
}

test "lines splits a reader on newlines, with or without a final one" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("alpha\n\nbeta\ngamma");
    const work = pipe(.{ filter(nonEmpty), print(Report, "[{f}]") });
    try support.run(program(lines(Input, 8), work), .{ Input{ .reader = &reader }, Report{ .writer = &writer } });
    try std.testing.expectEqualStrings("[alpha][beta][gamma]", writer.buffered());
}

test "lines stops reading when the pipe is done" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("one\ntwo\nthree\n");
    try support.run(program(lines(*std.Io.Reader, 8), pipe(.{ take(1), print(*std.Io.Writer, "{f}") })), .{ &reader, &writer });
    try std.testing.expectEqualStrings("one", writer.buffered());
    try std.testing.expectEqualStrings("two\nthree\n", reader.buffered());
}

fn shout(line: zrx.Line(64)) zrx.Line(64) {
    var upper = line;
    for (upper.bytes[0..upper.len]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return upper;
}

test "fileWriter and fileLines round-trip through the file system" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/lines.txt", .{tmp.sub_path});

    const words = [_][]const u8{ "red", "green", "blue" };
    try support.run(program(fromSlice(&words), pipe(.{ queue(1), print(Report, "{s}\n") })).provide(.{fileWriter(Report, path, 16, .{})}), .{io});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(path, 64), pipe(.{ map(shout), print(Log, "{f},") })), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", writer.buffered());
}

fn failAtThree(value: u32) error{Three}!u32 {
    if (value == 3) return error.Three;
    return value;
}

test "printed items stay written when a later item fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/partial.txt", .{tmp.sub_path});

    // Each successful print flushes its output before the later failure.
    const failing = program(range(u32, 0, 10), pipe(.{ map(failAtThree), print(Report, "{d}\n") })).provide(.{fileWriter(Report, path, 64, .{})});
    try std.testing.expectError(error.Three, support.run(failing, .{io}));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(path, 64), pipe(.{print(Log, "{f},")})), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("0,1,2,", writer.buffered());
}

test "fileWriter replaces an existing file unless asked to create a new file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/report.txt", .{tmp.sub_path});
    const first = [_][]const u8{ "old", "old" };
    const second = [_][]const u8{"new"};
    const third = [_][]const u8{"never written"};

    try support.run(program(fromSlice(&first), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{})}), .{io});
    try support.run(program(fromSlice(&second), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{})}), .{io});
    const exclusive = program(fromSlice(&third), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{ .mode = .create_new })});
    try std.testing.expectError(error.PathAlreadyExists, support.run(exclusive, .{io}));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(path, 64), pipe(.{print(Log, "{f},")})), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("new,", writer.buffered());
}

var flushes: usize = 0;

fn countFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {
    flushes += 1;
}

test "write flushes once, at the end of the stream, where print flushes every item" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var vtable = writer.vtable.*;
    vtable.flush = countFlush;
    writer.vtable = &vtable;

    flushes = 0;
    try support.run(program(range(u32, 1, 4), .{write(*std.Io.Writer, "{d};")}), .{&writer});
    try std.testing.expectEqualStrings("1;2;3;", writer.buffered());
    try std.testing.expectEqual(@as(usize, 1), flushes);

    flushes = 0;
    try support.run(program(range(u32, 1, 4), .{print(*std.Io.Writer, "{d};")}), .{&writer});
    try std.testing.expectEqual(@as(usize, 4), flushes);
}

test "write reports a flush error at stream end" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var vtable = writer.vtable.*;
    vtable.flush = failFlush;
    writer.vtable = &vtable;
    try std.testing.expectError(error.WriteFailed, support.run(program(range(u32, 0, 2), .{write(*std.Io.Writer, "{d}")}), .{&writer}));
    try std.testing.expectEqualStrings("01", writer.buffered());
}

fn filesIn(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| count += 1;
    return count;
}

test "a published file appears only when the run succeeds, and replaces nothing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/report.txt", .{tmp.sub_path});
    const published = fileWriter(Report, path, 4, .{ .mode = .publish });

    // A failed run leaves nothing behind, not even its temporary file.
    const failing = program(range(u32, 0, 10), .{ map(failAtThree), write(Report, "{d}\n") }).provide(.{published});
    try std.testing.expectError(error.Three, support.run(failing, .{io}));
    try std.testing.expectEqual(@as(usize, 0), try filesIn(tmp.dir));

    // A successful one publishes everything, including what was still buffered.
    try support.run(program(range(u32, 0, 3), .{write(Report, "{d}\n")}).provide(.{published}), .{io});
    try std.testing.expectEqual(@as(usize, 1), try filesIn(tmp.dir));

    // The path is now taken: a second run fails and the file is as it was.
    const again = program(range(u32, 7, 9), .{write(Report, "{d}\n")}).provide(.{published});
    try std.testing.expectError(error.PathAlreadyExists, support.run(again, .{io}));
    try std.testing.expectEqual(@as(usize, 1), try filesIn(tmp.dir));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(path, 64), .{print(Log, "{f},")}), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("0,1,2,", writer.buffered());
}

test "a writer given to run replaces a file default, and no file is created" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/report.txt", .{tmp.sub_path});
    const report = program(range(u32, 0, 3), .{write(Report, "{d},")}).provide(.{fileWriter(Report, path, 16, .{})});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(report, .{ Report{ .writer = &writer }, io });
    try std.testing.expectEqualStrings("0,1,2,", writer.buffered());
    try std.testing.expectEqual(@as(usize, 0), try filesIn(tmp.dir));

    // A file given to `run` may come before the `Io` it needs.
    try support.run(program(range(u32, 0, 3), .{write(Report, "{d},")}), .{ fileWriter(Report, path, 16, .{}), io });
    try std.testing.expectEqual(@as(usize, 1), try filesIn(tmp.dir));
}

const Name = zrx.Line(4);
const Pet = struct { name: Name, legs: u32 };

fn named(text: []const u8) !Pet {
    return .{ .name = try .from(text), .legs = 4 };
}

fn json(pet: Pet) std.json.Formatter(Pet) {
    return std.json.fmt(pet, .{});
}

test "a line copies bounded text and is a string to std.json" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const names = [_][]const u8{ "rex", "", "judy" };
    try support.run(program(fromSlice(&names), .{ map(named), map(json), write(*std.Io.Writer, "{f}\n") }), .{&writer});
    try std.testing.expectEqualStrings(
        \\{"name":"rex","legs":4}
        \\{"name":"","legs":4}
        \\{"name":"judy","legs":4}
        \\
    , writer.buffered());

    try std.testing.expectError(error.StreamTooLong, Name.from("tiger"));
}

test "a line that is not UTF-8 is an array of numbers to std.json, like any such bytes" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const bytes = "a\xff";
    try writer.print("{f} {f}", .{ std.json.fmt(try Name.from(bytes), .{}), std.json.fmt(@as([]const u8, bytes), .{}) });
    try std.testing.expectEqualStrings("[97,255] [97,255]", writer.buffered());
}

fn toBoth(report: Report, log: Log, value: u32) !void {
    try report.writer.print("{d}\n", .{value});
    try log.writer.print("saw {d}\n", .{value});
}

test "published files are named one by one, the last bound first, and one failing leaves the others" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var report_bytes: [128]u8 = undefined;
    var log_bytes: [128]u8 = undefined;
    const report_path = try std.fmt.bufPrint(&report_bytes, ".zig-cache/tmp/{s}/report.txt", .{tmp.sub_path});
    const log_path = try std.fmt.bufPrint(&log_bytes, ".zig-cache/tmp/{s}/log.txt", .{tmp.sub_path});
    // The first file bound is named last, and its path is taken.
    try tmp.dir.writeFile(io, .{ .sub_path = "report.txt", .data = "taken\n" });

    const both = program(range(u32, 0, 2), .{zrx.forEach(toBoth)}).provide(.{
        fileWriter(Report, report_path, 64, .{ .mode = .publish }),
        fileWriter(Log, log_path, 64, .{ .mode = .publish }),
    });
    try std.testing.expectError(error.PathAlreadyExists, support.run(both, .{io}));

    // The run failed, and the file named before the failure is there, whole.
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(log_path, 64), .{print(*std.Io.Writer, "{f},")}), .{ io, &writer });
    try support.run(program(fileLines(report_path, 64), .{print(*std.Io.Writer, "{f},")}), .{ io, &writer });
    try std.testing.expectEqualStrings("saw 0,saw 1,taken,", writer.buffered());
}

fn unflushed(report: Report, value: u32) !void {
    try report.writer.print("{d}\n", .{value});
}

test "a published file holds what a handler wrote without flushing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/direct.txt", .{tmp.sub_path});
    // The buffer holds everything: nothing reaches the file before the publish.
    try support.run(program(range(u32, 0, 3), .{zrx.forEach(unflushed)}).provide(.{fileWriter(Report, path, 64, .{ .mode = .publish })}), .{io});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(program(fileLines(path, 64), .{print(Log, "{f},")}), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("0,1,2,", writer.buffered());
}

/// One program for every test below: where its lines come from is a binding.
const shouted = program(lines(Input, 8), .{
    map(shoutShort),
    print(Log, "{f},"),
});

fn shoutShort(line: zrx.Line(8)) zrx.Line(8) {
    var upper = line;
    for (upper.bytes[0..upper.len]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return upper;
}

test "fileReader binds a file for lines, given to provide or to run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "words", .data = "red\ngreen\nblue" });
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/words", .{tmp.sub_path});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try support.run(shouted, .{ io, fileReader(Input, path, 9), Log{ .writer = &writer } });
    try support.run(shouted.provide(.{fileReader(Input, path, 9)}), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,RED,GREEN,BLUE,", writer.buffered());
}

test "a reader given to run replaces a fileReader default, and its file is not opened" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("in\nmemory");
    const from_file = shouted.provide(.{fileReader(Input, ".zig-cache/tmp/zrx-no-such-file", 9)});
    try support.run(from_file, .{ io, Input{ .reader = &reader }, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("IN,MEMORY,", writer.buffered());

    // Left to its default, the same program fails before any item.
    try std.testing.expectError(error.FileNotFound, support.run(from_file, .{ io, Log{ .writer = &writer } }));
    try std.testing.expectEqualStrings("IN,MEMORY,", writer.buffered());
}

test "the line limit counts the line, not its newline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "fits", .data = "ABCD\nEF\nGHIJ" });
    try tmp.dir.writeFile(io, .{ .sub_path = "too-long", .data = "AB\nABCDE\n" });
    var path_bytes: [128]u8 = undefined;

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const fits = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/fits", .{tmp.sub_path});
    try support.run(program(fileLines(fits, 4), pipe(.{print(Log, "{f},")})), .{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("ABCD,EF,GHIJ,", writer.buffered());

    var second: [64]u8 = undefined;
    var rejected: std.Io.Writer = .fixed(&second);
    const too_long = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/too-long", .{tmp.sub_path});
    const result = support.run(program(fileLines(too_long, 4), pipe(.{print(Log, "{f},")})), .{ io, Log{ .writer = &rejected } });
    try std.testing.expectError(error.StreamTooLong, result);
    try std.testing.expectEqualStrings("AB,", rejected.buffered());
}

test "a larger line limit can retry on the same reader, including at EOF" {
    const cases = [_]struct { input: []const u8, output: []const u8 }{
        .{ .input = "ABCDE\nok\n", .output = "[ABCDE][ok]" },
        .{ .input = "ABCDE", .output = "[ABCDE]" },
    };
    const first = program(lines(*std.Io.Reader, 4), pipe(.{zrx.drain()}));
    const retry = program(lines(*std.Io.Reader, 5), pipe(.{print(*std.Io.Writer, "[{f}]")}));
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.input);
        try std.testing.expectError(error.StreamTooLong, support.run(first, .{&reader}));

        var buffer: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try support.run(retry, .{ &reader, &writer });
        try std.testing.expectEqualStrings(case.output, writer.buffered());
    }
}

test "file lines survive batching and a queue, including the final partial batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "AAAA\nBBBB\nCCCC" });
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/lines", .{tmp.sub_path});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const work = pipe(.{
        zrx.batch(2),
        queue(1),
        zrx.flatten(),
        print(*std.Io.Writer, "[{f}]"),
    });
    try support.run(program(fileLines(path, 4), work), .{ io, &writer });
    try std.testing.expectEqualStrings("[AAAA][BBBB][CCCC]", writer.buffered());
}

const LargeLine = zrx.Line(32 * 1024);
var large_line_slots: [1024]LargeLine = undefined;

fn runLargeLineQueue(result: *anyerror!void) void {
    result.* = checkLargeLineQueue();
}

fn checkLargeLineQueue() !void {
    var reader: std.Io.Reader = .fixed("one\ntwo\nthree");
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const work = pipe(.{
        queue(&large_line_slots),
        print(*std.Io.Writer, "{f};"),
    });
    try support.run(program(lines(*std.Io.Reader, 32 * 1024), work), .{ io, &reader, &writer });
    try std.testing.expectEqualStrings("one;two;three;", writer.buffered());
}

test "a borrowed queue of large lines fits a small caller stack without an allocator dependency" {
    var result: anyerror!void = undefined;
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runLargeLineQueue, .{&result});
    thread.join();
    try result;
}

test "a missing file fails the run before any item" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = support.run(program(fileLines(".zig-cache/tmp/zrx-no-such-file", 64), pipe(.{print(*std.Io.Writer, "{f}")})), .{ io, &writer });
    try std.testing.expectError(error.FileNotFound, result);
}

// --- file bytes -------------------------------------------------------------------

/// The pieces a file came in, put together again.
const Pieces = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    count: usize = 0,
    longest: usize = 0,
    empty: usize = 0,

    fn add(pieces: *Pieces, piece: []const u8) void {
        @memcpy(pieces.bytes[pieces.len..][0..piece.len], piece);
        pieces.len += piece.len;
        pieces.count += 1;
        pieces.longest = @max(pieces.longest, piece.len);
        if (piece.len == 0) pieces.empty += 1;
    }
};

test "fileBytes gives the bytes of a file in order, at most n at a time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/bytes", .{tmp.sub_path});
    const content = "0123456789abcdefghijklmnopqrstuvwxyz";

    // Shorter than a piece, exactly one, one more, several and a rest; and nothing.
    for ([_]usize{ 0, 1, 7, 8, 9, 16, 36 }) |size| {
        try tmp.dir.writeFile(io, .{ .sub_path = "bytes", .data = content[0..size] });
        var pieces: Pieces = .{};
        try support.run(program(fileBytes(path, 8), .{forEach(Pieces.add)}), .{ io, &pieces });
        try std.testing.expectEqualStrings(content[0..size], pieces.bytes[0..pieces.len]);
        try std.testing.expectEqual(try std.math.divCeil(usize, size, 8), pieces.count);
        try std.testing.expect(pieces.longest <= 8);
        try std.testing.expectEqual(@as(usize, 0), pieces.empty);
    }

    // It stops when the pipe is done: no piece is pushed after that.
    var first: Pieces = .{};
    var pushed: usize = 0;
    try support.run(program(fileBytes(path, 8), .{ zrx.tap(countPiece), take(1), forEach(Pieces.add) }), .{ io, &first, &pushed });
    try std.testing.expectEqualStrings(content[0..8], first.bytes[0..first.len]);
    try std.testing.expectEqual(@as(usize, 1), pushed);
}

fn countPiece(pushed: *usize, _: []const u8) void {
    pushed.* += 1;
}

test "a file that cannot be opened or read fails the run with the error the system gave" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bytes", .data = "unread" });
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/bytes", .{tmp.sub_path});

    var pieces: Pieces = .{};
    const missing = support.run(program(fileBytes(".zig-cache/tmp/zrx-no-such-file", 8), .{forEach(Pieces.add)}), .{ io, &pieces });
    try std.testing.expectError(error.FileNotFound, missing);
    // `std.Io.File.Reader` reports `error.ReadFailed` and keeps the cause.
    const unreadable = support.run(program(fileBytes(path, 8), .{forEach(Pieces.add)}), .{ support.ReadFails.over(io), &pieces });
    try std.testing.expectError(error.InputOutput, unreadable);
    try std.testing.expectEqual(@as(usize, 0), pieces.count);
}

test "fileLines fails the run with the error the system gave when a read fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "unread\n" });
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/lines", .{tmp.sub_path});

    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const failing = support.ReadFails.over(io);
    const from_source = support.run(program(fileLines(path, 8), .{print(Log, "{f},")}), .{ failing, Log{ .writer = &writer } });
    try std.testing.expectError(error.InputOutput, from_source);
    try std.testing.expectEqualStrings("", writer.buffered());
}

/// Reads from the bound file, handles that failure, then fails with a
/// `ReadFailed` that is not the file's.
fn readThenFail(input: Input, _: u32) error{ReadFailed}!void {
    _ = input.reader.peekByte() catch {};
    return error.ReadFailed;
}

test "a reader bound by fileReader reports ReadFailed, its own and anyone else's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "unread\n" });
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/lines", .{tmp.sub_path});

    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const failing = support.ReadFails.over(io);
    const own = support.run(program(lines(Input, 8), .{print(Log, "{f},")}), .{ failing, fileReader(Input, path, 9), Log{ .writer = &writer } });
    try std.testing.expectError(error.ReadFailed, own);
    // The binding cannot tell whose failure it is, so it names no cause:
    // the file's recorded one would be wrong here.
    const other = support.run(program(range(u32, 0, 1), .{zrx.forEach(readThenFail)}), .{ failing, fileReader(Input, path, 9) });
    try std.testing.expectError(error.ReadFailed, other);
}

// path -> its bytes -> one digest -> a row, as the guide writes it.

const Sha256 = std.crypto.hash.sha2.Sha256;
const read_bytes = 4096;

/// The running digest of one file.
const Hash = struct {
    sha: Sha256 = .init(.{}),
    bytes: u64 = 0,

    fn update(hash: Hash, piece: []const u8) Hash {
        var next = hash;
        next.sha.update(piece);
        next.bytes += piece.len;
        return next;
    }
};

/// A hashed file, or what went wrong with it.
const Row = struct {
    path: []const u8,
    bytes: u64 = 0,
    sha256: [Sha256.digest_length]u8 = @splat(0),
    failure: ?anyerror = null,
};

fn bytesOf(path: []const u8) zrx.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}
fn described(file: zrx.Tagged([]const u8, Hash)) Row {
    var sha = file.item.sha;
    return .{ .path = file.source, .bytes = file.item.bytes, .sha256 = sha.finalResult() };
}
fn failed(failure: zrx.Failed(anyerror, []const u8)) Row {
    return .{ .path = failure.item, .failure = failure.err };
}

const digest = pipe(.{fold(Hash{}, Hash.update)});

const hashed = pipe(.{
    each(bytesOf, digest),
    map(described),
});

test "files of several sizes are hashed by concurrent workers, and a missing one becomes a row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sizes = [_]usize{ 0, 1, read_bytes - 1, read_bytes, read_bytes + 1, 3 * read_bytes + 7, 100_003 };
    const content = try std.testing.allocator.alloc(u8, sizes[sizes.len - 1]);
    defer std.testing.allocator.free(content);
    var random: std.Random.DefaultPrng = .init(0x5eed);
    random.random().bytes(content);

    var names: [sizes.len + 1][128]u8 = undefined;
    var paths: [sizes.len + 1][]const u8 = undefined;
    var expected: [sizes.len][Sha256.digest_length]u8 = undefined;
    for (sizes, 0..) |size, i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "file-{d}", .{i}), .data = content[0..size] });
        paths[i] = try std.fmt.bufPrint(&names[i], ".zig-cache/tmp/{s}/file-{d}", .{ tmp.sub_path, i });
        Sha256.hash(content[0..size], &expected[i], .{});
    }
    paths[sizes.len] = try std.fmt.bufPrint(&names[sizes.len], ".zig-cache/tmp/{s}/missing", .{tmp.sub_path});

    var rows: support.Recorder(Row) = .{};
    const manifest = pipe(.{
        concurrent(4, .{attempt(hashed, anyerror, .{map(failed)})}),
        forEach(support.record(Row)),
    });
    // Twice over, so that workers have files of every size to share.
    for (0..2) |_| try support.run(program(fromSlice(&paths), manifest), .{ io, &rows });

    try std.testing.expectEqual(2 * paths.len, rows.len);
    var found: [paths.len]usize = @splat(0);
    for (rows.slice()) |row| {
        const i = for (paths, 0..) |path, i| {
            if (std.mem.eql(u8, path, row.path)) break i;
        } else return error.UnknownPath;
        found[i] += 1;
        if (i == sizes.len) {
            try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), row.failure);
        } else {
            try std.testing.expectEqual(@as(?anyerror, null), row.failure);
            try std.testing.expectEqual(@as(u64, sizes[i]), row.bytes);
            try std.testing.expectEqualSlices(u8, &expected[i], &row.sha256);
        }
    }
    try std.testing.expectEqualSlices(usize, &@as([paths.len]usize, @splat(2)), &found);
}

// --- cancellation inside a write --------------------------------------------------
//
// `std.Io.Writer` reports every failure as `error.WriteFailed`, a request to
// cancel included. `support.WriteHeld` holds a write until its task has been
// asked to cancel, so that this happens at a chosen moment.

const Skipped = struct {
    count: std.atomic.Value(usize) = .init(0),
};

/// The end of an ordinary error path: note the failure and go on.
fn skip(skipped: *Skipped, _: zrx.Failed(anyerror, u32)) void {
    _ = skipped.count.fetchAdd(1, .seq_cst);
}

/// Fails once the segment behind the queue is writing its first line.
fn pushThenFailOnceWriting(out: anytype) !void {
    _ = try out.push(@as(u32, 1));
    while (!support.WriteHeld.writing.load(.seq_cst)) std.Thread.yield() catch {};
    return error.SourceFailed;
}

test "a failure ends the run although the segment it interrupts is printing under a recover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/out.txt", .{tmp.sub_path});

    var skipped: Skipped = .{};
    // A buffer of one byte: every line is written as it is printed. The
    // request to cancel reaches the segment inside that write and comes out
    // as a failed write, which the recover takes for an item error. The
    // segment has no request left, and still comes to an end.
    const work = pipe(.{
        queue(2),
        recover(anyerror, .{forEach(skip)}),
        print(Report, "{d}\n"),
    });
    const result = support.run(program(fromProducer(u32, pushThenFailOnceWriting), work).provide(.{fileWriter(Report, path, 1, .{})}), .{ support.WriteHeld.over(io), &skipped });
    try std.testing.expectError(error.SourceFailed, result);
}
