//! Byte and line I/O.
const std = @import("std");
const zrx = @import("zrx");
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
const createFile = zrx.createFile;

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

fn nonEmpty(line: []const u8) bool {
    return line.len != 0;
}

test "lines splits a reader on newlines, with or without a final one" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("alpha\n\nbeta\ngamma");
    const work = pipe(.{ filter(nonEmpty), print(Report, "[{s}]") });
    try program(lines(Input), work).run(.{ Input{ .reader = &reader }, Report{ .writer = &writer } });
    try std.testing.expectEqualStrings("[alpha][beta][gamma]", writer.buffered());
}

test "lines stops reading when the pipe is done" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var reader: std.Io.Reader = .fixed("one\ntwo\nthree\n");
    try program(lines(*std.Io.Reader), pipe(.{ take(1), print(*std.Io.Writer, "{s}") })).run(.{ &reader, &writer });
    try std.testing.expectEqualStrings("one", writer.buffered());
    try std.testing.expectEqualStrings("two\nthree\n", reader.buffered());
}

fn shout(buffer: *[32]u8, line: []const u8) []const u8 {
    return std.ascii.upperString(buffer, line);
}

test "createFile and fileLines round-trip through the file system" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_bytes: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/lines.txt", .{tmp.sub_path});

    const words = [_][]const u8{ "red", "green", "blue" };
    try program(fromSlice(&words), pipe(.{ createFile(Report, path, 16), print(Report, "{s}\n") })).run(.{io});

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var scratch: [32]u8 = undefined;
    try program(fileLines(path, 64), pipe(.{ map(shout), print(Log, "{s},") })).run(.{ io, &scratch, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", writer.buffered());
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
    try program(fileLines(fits, 4), pipe(.{print(Log, "{s},")})).run(.{ io, Log{ .writer = &writer } });
    try std.testing.expectEqualStrings("ABCD,EF,GHIJ,", writer.buffered());

    var second: [64]u8 = undefined;
    var rejected: std.Io.Writer = .fixed(&second);
    const too_long = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/too-long", .{tmp.sub_path});
    const result = program(fileLines(too_long, 4), pipe(.{print(Log, "{s},")})).run(.{ io, Log{ .writer = &rejected } });
    try std.testing.expectError(error.StreamTooLong, result);
    try std.testing.expectEqualStrings("AB,", rejected.buffered());
}

test "a missing file fails the run before any item" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = program(fileLines(".zig-cache/tmp/zrx-no-such-file", 64), pipe(.{print(*std.Io.Writer, "{s}")})).run(.{ io, &writer });
    try std.testing.expectError(error.FileNotFound, result);
}
