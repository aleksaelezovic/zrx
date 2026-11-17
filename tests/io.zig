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
const lines = zrx.lines;
const fileLines = zrx.fileLines;
const fileWriter = zrx.fileWriter;
const fromProducer = zrx.fromProducer;
const queue = zrx.queue;
const recover = zrx.recover;

const Report = struct { writer: *std.Io.Writer };
const Log = struct { writer: *std.Io.Writer };
const Input = struct { reader: *std.Io.Reader };

test "print formats every item to the writer it is given" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try program(range(u32, 1, 4), pipe(.{print(*std.Io.Writer, "{d};")})).run(.{&writer});
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
    try std.testing.expectError(error.WriteFailed, program(range(u32, 0, 1), output).run(.{&writer}));
    try std.testing.expectEqualStrings("0", writer.buffered());
    try std.testing.expectError(error.WriteFailed, program(range(u32, 0, 0), output).run(.{&writer}));
}

test "a tuple item supplies several format arguments" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const entries = [_]Entry{ .{ .name = "ada", .score = 3 }, .{ .name = "bob", .score = 5 } };
    try program(fromSlice(&entries), pipe(.{ map(fields), print(Report, "{s}={d}\n") })).run(.{Report{ .writer = &writer }});
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
    try program(range(u32, 1, 4), work).run(.{ Report{ .writer = &report }, Log{ .writer = &log } });
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
    try program(lines(Input, 8), work).run(.{ Input{ .reader = &reader }, Report{ .writer = &writer } });
    try std.testing.expectEqualStrings("[alpha][beta][gamma]", writer.buffered());
}

test "lines stops reading when the pipe is done" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("one\ntwo\nthree\n");
    try program(lines(*std.Io.Reader, 8), pipe(.{ take(1), print(*std.Io.Writer, "{f}") })).run(.{ &reader, &writer });
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
    try program(fromSlice(&words), pipe(.{ queue(1), print(Report, "{s}\n") })).provide(.{fileWriter(Report, path, 16, .{})}).run(.{io});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try program(fileLines(path, 64), pipe(.{ map(shout), print(Log, "{f},") })).run(.{ io, Log{ .writer = &writer } });
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
    try std.testing.expectError(error.Three, failing.run(.{io}));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try program(fileLines(path, 64), pipe(.{print(Log, "{f},")})).run(.{ io, Log{ .writer = &writer } });
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

    try program(fromSlice(&first), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{})}).run(.{io});
    try program(fromSlice(&second), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{})}).run(.{io});
    const exclusive = program(fromSlice(&third), pipe(.{print(Report, "{s}\n")})).provide(.{fileWriter(Report, path, 16, .{ .mode = .create_new })});
    try std.testing.expectError(error.PathAlreadyExists, exclusive.run(.{io}));

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try program(fileLines(path, 64), pipe(.{print(Log, "{f},")})).run(.{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("new,", writer.buffered());
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
    try program(fileLines(fits, 4), pipe(.{print(Log, "{f},")})).run(.{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("ABCD,EF,GHIJ,", writer.buffered());

    var second: [64]u8 = undefined;
    var rejected: std.Io.Writer = .fixed(&second);
    const too_long = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/too-long", .{tmp.sub_path});
    const result = program(fileLines(too_long, 4), pipe(.{print(Log, "{f},")})).run(.{ io, Log{ .writer = &rejected } });
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
        try std.testing.expectError(error.StreamTooLong, first.run(.{&reader}));

        var buffer: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try retry.run(.{ &reader, &writer });
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
    try program(fileLines(path, 4), work).run(.{ io, &writer });
    try std.testing.expectEqualStrings("[AAAA][BBBB][CCCC]", writer.buffered());
}

test "a missing file fails the run before any item" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = program(fileLines(".zig-cache/tmp/zrx-no-such-file", 64), pipe(.{print(*std.Io.Writer, "{f}")})).run(.{ io, &writer });
    try std.testing.expectError(error.FileNotFound, result);
}

// --- cancellation inside a write --------------------------------------------------
//
// `std.Io.Writer` reports every failure as `error.WriteFailed`, a request to
// cancel included. `support.WriteHeld` holds a write until its task has been
// asked to cancel, so that this happens at a chosen moment.

const Skipped = struct {
    count: std.atomic.Value(usize) = .init(0),
};

/// An ordinary `recover` handler: note the item and go on.
fn skip(skipped: *Skipped, _: anyerror, _: u32) void {
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
        recover(skip),
        print(Report, "{d}\n"),
    });
    const result = program(fromProducer(u32, pushThenFailOnceWriting), work).provide(.{fileWriter(Report, path, 1, .{})}).run(.{ support.WriteHeld.over(io), &skipped });
    try std.testing.expectError(error.SourceFailed, result);
}
