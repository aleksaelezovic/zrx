//! `zrx.ext.process`: the standard streams of a process as bindings, its
//! exit status, and the handlers that set it.
const std = @import("std");
const zrx = @import("zrx");
const support = @import("support.zig");

const Io = std.Io;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const lines = zrx.lines;
const map = zrx.map;
const tap = zrx.tap;
const take = zrx.take;
const filter = zrx.filter;
const forEach = zrx.forEach;
const print = zrx.print;
const recover = zrx.recover;
const rescue = zrx.rescue;
const fileReader = zrx.fileReader;
const fileWriter = zrx.fileWriter;
const process = zrx.ext.process;

const Stdin = process.Stdin;
const Stdout = process.Stdout;
const Stderr = process.Stderr;
const stdin = process.stdin;
const stdout = process.stdout;
const stderr = process.stderr;

const Seen = struct { sum: u32 = 0 };

fn small(value: u32) error{TooBig}!u32 {
    if (value > 2) return error.TooBig;
    return value;
}
fn interrupted(value: u32) error{Canceled}!u32 {
    if (value > 2) return error.Canceled;
    return value;
}
fn unknown(value: u32) anyerror!u32 {
    if (value > 2) return error.Unexpected;
    return value;
}
fn note(seen: *Seen, value: u32) void {
    seen.sum += value;
}
fn warn(exit: *process.Exit, _: u32) void {
    exit.code = 1;
}

const few = [_]u32{ 1, 2 };
const many = [_]u32{ 1, 2, 3, 4 };

/// Sums its items, and fails with `error.TooBig` at the first above 2.
fn summed(items: []const u32) @TypeOf(program(fromSlice(&many), .{ map(small), forEach(note) })) {
    return program(fromSlice(items), .{ map(small), forEach(note) });
}

test "a run that succeeds leaves status 0 and writes nothing" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&few).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{})) });
    try std.testing.expectEqual(0, exit.code);
    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(3, seen.sum);
}

test "a run that fails leaves status 1 and a line that names the error" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());
    try std.testing.expectEqual(3, seen.sum);
}

test "the status and the prefix are options" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 2, .prefix = "fatal" })) });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("fatal: TooBig\n", writer.buffered());
}

test "without a prefix nothing is written, and no stderr is asked for" {
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, rescue(process.fail(.{ .status = 3, .prefix = null })) });
    try std.testing.expectEqual(3, exit.code);

    exit = .{};
    seen = .{};
    summed(&few).run(.{ &seen, &exit, rescue(process.fail(.{ .status = 3, .prefix = null })) });
    try std.testing.expectEqual(0, exit.code);
}

test "a stderr the rescue is given for itself is replaced by one given to run" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    // As a program is written for `main`. Nothing here has an `Io`, so the
    // rescue's own stderr is not acquired.
    const bound = summed(&many).provide(.{rescue(process.fail(.{ .prefix = "fatal" })).provide(.{stderr(Stderr, 256)})});
    bound.run(.{ &seen, &exit, Stderr{ .writer = &writer } });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("fatal: TooBig\n", writer.buffered());
}

test "a prefix is written as it is, braces too" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .prefix = "{copy} lines" })) });
    try std.testing.expectEqualStrings("{copy} lines: TooBig\n", writer.buffered());
    try std.testing.expectEqual(1, exit.code);
}

test "the failure's status replaces what a stage left" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    const judged = program(fromSlice(&many), .{ tap(warn), map(small), forEach(note) });
    judged.run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());

    // And a stage's status stays where the run does not fail.
    exit = .{};
    program(fromSlice(&few), .{ tap(warn), map(small), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(1, exit.code);
}

test "a cancellation is reported like any failure" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    program(fromSlice(&many), .{ map(interrupted), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 130 })) });
    try std.testing.expectEqual(130, exit.code);
    try std.testing.expectEqualStrings("error: Canceled\n", writer.buffered());
}

test "a run that can fail with any error is reported by the name of the one it failed with" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    program(fromSlice(&many), .{ map(unknown), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: Unexpected\n", writer.buffered());
}

test "the status is left also when the line does not fit" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(2, exit.code);
}

test "the line is flushed, and a flush that fails is nobody's" {
    // Buffers what it is given and fails when asked to pass it on.
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .{
        .vtable = &.{ .drain = Flushes.drain },
        .buffer = &buffer,
    };
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    Flushes.count = 0;
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());
    try std.testing.expectEqual(1, Flushes.count);
}

const Flushes = struct {
    var count: u32 = 0;

    fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        count += 1;
        return error.WriteFailed;
    }
};

test "a program of one error says the same of what failed before there was a run" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    const refusal = process.fail(.{ .status = 2, .prefix = "fatal" });
    program(fromValue(error.InvalidArguments), .{forEach(refusal)}).run(.{ &exit, Stderr{ .writer = &writer } });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("fatal: InvalidArguments\n", writer.buffered());

    // An error whose name is known only when it happens.
    exit = .{};
    writer = .fixed(&buffer);
    const failed: anyerror = error.FileNotFound;
    program(fromValue(failed), .{forEach(refusal)}).run(.{ &exit, Stderr{ .writer = &writer } });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("fatal: FileNotFound\n", writer.buffered());
}

fn quoted(value: u32) error{@"Too\nbig"}!u32 {
    if (value > 2) return error.@"Too\nbig";
    return value;
}

test "a byte of a name that is not printable is escaped, and the line stays one" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    program(fromSlice(&many), .{ map(quoted), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: Too\\x0abig\n", writer.buffered());

    // Under `anyerror`, where the name is known only when it happens: a
    // carriage return and an escape, a line separator of Unicode, and
    // printable bytes that are no identifier's, which stay.
    const refusal = process.fail(.{ .status = 2, .prefix = "fatal" });
    const names = [_]struct { anyerror, []const u8 }{
        .{ error.@"a\r\x1b[2Kb", "fatal: a\\x0d\\x1b[2Kb\n" },
        .{ error.@"one\u{2028}two", "fatal: one\\xe2\\x80\\xa8two\n" },
        .{ error.@"not \"one\" {name}", "fatal: not \"one\" {name}\n" },
    };
    for (names) |case| {
        writer = .fixed(&buffer);
        program(fromValue(case[0]), .{forEach(refusal)}).run(.{ &exit, Stderr{ .writer = &writer } });
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

/// As the guide writes a program, its `main` and what it does about wrong
/// arguments, with the streams of the process itself. Compiled, not run.
const fatal = process.fail(.{ .status = 2, .prefix = "fatal" });

fn parsed(line: zrx.Line(8)) error{InvalidRecord}!zrx.Line(8) {
    if (line.len == 0) return error.InvalidRecord;
    return line;
}

const app = program(lines(Input, 8), .{
    recover(error{InvalidRecord}, .{forEach(process.status(1))}),
    map(parsed),
    print(Output, "{f}\n"),
}).provide(.{
    stdout(Output, 4096),
    rescue(fatal).provide(.{stderr(Stderr, 256)}),
});

fn refuse(io: Io, exit: *process.Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(Stderr, 256) });
}

fn main(io: Io, args: []const [:0]const u8) u8 {
    var exit: process.Exit = .{};
    if (args.len > 2) {
        refuse(io, &exit, error.InvalidArguments);
    } else if (args.len == 2) {
        app.run(.{ io, &exit, fileReader(Input, args[1], 9) });
    } else {
        app.run(.{ io, &exit, stdin(Input, 9) });
    }
    return exit.code;
}

test "a main with the streams of the process compiles, and runs on streams of memory" {
    const io = Streams.over(std.testing.io, "ab\n\ncd\n");
    try std.testing.expectEqual(1, main(io, &.{"app"}));
    try std.testing.expectEqualStrings("ab\ncd\n", Streams.out.text());
    try std.testing.expectEqualStrings("", Streams.err.text());

    _ = Streams.over(std.testing.io, "");
    try std.testing.expectEqual(2, main(io, &.{ "app", ".zig-cache/tmp/zrx-no-such-file" }));
    try std.testing.expectEqualStrings("fatal: FileNotFound\n", Streams.err.text());

    _ = Streams.over(std.testing.io, "");
    try std.testing.expectEqual(2, main(io, &.{ "app", "one", "two" }));
    try std.testing.expectEqualStrings("fatal: InvalidArguments\n", Streams.err.text());
}

test "the arguments of a process are a source as they are" {
    // Nothing of arguments is in the extension: these two are what one writes.
    const Iterated = @TypeOf(zrx.fromIterator(@as(*std.process.Args.Iterator, undefined)));
    try std.testing.expect(Iterated.Item == [:0]const u8);
    const Sliced = @TypeOf(fromSlice(@as([]const [:0]const u8, &.{})));
    try std.testing.expect(Sliced.Item == [:0]const u8);
}

// ---------------------------------------------------------------------------
// The standard streams
// ---------------------------------------------------------------------------

test "the roles of the streams are the ones the core names" {
    // Until `zrx.Stdout` and `zrx.Stderr` leave the core there are two
    // names, and one type behind them.
    try std.testing.expect(process.Stdout == zrx.Stdout);
    try std.testing.expect(process.Stderr == zrx.Stderr);
}

/// An `Io` whose standard streams are memory: what is read from standard
/// input is served from `input`, a few bytes at a time, and what is written
/// to standard output and standard error is kept. Everything else is the
/// `Io` under it. One at a time: its state is global.
const Streams = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var input: []const u8 = "";
    var reads: usize = 0;
    var broken = false;
    var out: Kept = .{};
    var err: Kept = .{};

    const Kept = struct {
        bytes: [256]u8 = undefined,
        len: usize = 0,

        fn add(kept: *Kept, bytes: []const u8) usize {
            @memcpy(kept.bytes[kept.len..][0..bytes.len], bytes);
            kept.len += bytes.len;
            return bytes.len;
        }

        fn text(kept: *const Kept) []const u8 {
            return kept.bytes[0..kept.len];
        }
    };

    fn over(under: Io, text: []const u8) Io {
        inner = under;
        vtable = under.vtable.*;
        vtable.operate = operate;
        input = text;
        reads = 0;
        broken = false;
        out = .{};
        err = .{};
        return .{ .userdata = under.userdata, .vtable = &vtable };
    }

    fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
        switch (operation) {
            .file_read_streaming => |read| if (read.file.handle == Io.File.stdin().handle) {
                reads += 1;
                if (broken) return .{ .file_read_streaming = error.InputOutput };
                if (input.len == 0) return .{ .file_read_streaming = error.EndOfStream };
                for (read.data) |part| {
                    if (part.len == 0) continue;
                    const count = @min(part.len, input.len, 3);
                    @memcpy(part[0..count], input[0..count]);
                    input = input[count..];
                    return .{ .file_read_streaming = count };
                }
                return .{ .file_read_streaming = 0 };
            },
            .file_write_streaming => |written| {
                const kept = if (written.file.handle == Io.File.stdout().handle)
                    &out
                else if (written.file.handle == Io.File.stderr().handle)
                    &err
                else
                    return inner.vtable.operate(userdata, operation);
                var count = kept.add(written.header);
                for (written.data, 1..) |part, nth| {
                    for (0..if (nth == written.data.len) written.splat else 1) |_| count += kept.add(part);
                }
                return .{ .file_write_streaming = count };
            },
            else => {},
        }
        return inner.vtable.operate(userdata, operation);
    }
};

const Input = struct { reader: *Io.Reader };
const Output = struct { writer: *Io.Writer };

fn shout(line: zrx.Line(8)) zrx.Line(8) {
    var upper = line;
    for (upper.bytes[0..upper.len]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return upper;
}

/// One program: where its lines come from and where they go is not in it.
const shouted = program(lines(Input, 8), .{
    map(shout),
    print(Output, "{f},"),
});

const words = "red\ngreen\nblue";

/// `.zig-cache/tmp/<the directory of tmp>/<name>`, where the tests run.
fn tmpPath(buffer: []u8, tmp: *const std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "one program reads a file or standard input, by the binding it is run with" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = Streams.over(std.testing.io, words);
    try tmp.dir.writeFile(io, .{ .sub_path = "words", .data = words });
    var path_bytes: [128]u8 = undefined;
    const path = try tmpPath(&path_bytes, &tmp, "words");

    var from_file: [64]u8 = undefined;
    var file_writer: Io.Writer = .fixed(&from_file);
    try support.run(shouted, .{ io, fileReader(Input, path, 9), Output{ .writer = &file_writer } });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", file_writer.buffered());
    try std.testing.expectEqual(0, Streams.reads);

    var from_stdin: [64]u8 = undefined;
    var stdin_writer: Io.Writer = .fixed(&from_stdin);
    try support.run(shouted, .{ io, stdin(Input, 9), Output{ .writer = &stdin_writer } });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", stdin_writer.buffered());
    try std.testing.expect(Streams.reads > 0);
    try std.testing.expectEqualStrings("", Streams.input);
}

test "one program writes a file or standard output, by the binding it is run with" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = Streams.over(std.testing.io, words);
    var path_bytes: [128]u8 = undefined;
    const path = try tmpPath(&path_bytes, &tmp, "shouted");

    try support.run(shouted, .{ io, stdin(Input, 9), fileWriter(Output, path, 64, .{}) });
    var read_bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", try tmp.dir.readFile(io, "shouted", &read_bytes));
    try std.testing.expectEqualStrings("", Streams.out.text());

    Streams.input = words;
    try support.run(shouted, .{ io, stdin(Input, 9), stdout(Output, 64) });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", Streams.out.text());
    try std.testing.expectEqualStrings("", Streams.err.text());

    // And to standard error, by the same role.
    Streams.input = words;
    try support.run(shouted, .{ io, stdin(Input, 9), stderr(Output, 64) });
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", Streams.out.text());
    try std.testing.expectEqualStrings("RED,GREEN,BLUE,", Streams.err.text());
}

test "the streams under their own roles, and under the interfaces themselves" {
    const io = Streams.over(std.testing.io, words);
    const named = program(lines(Stdin, 8), .{ map(shout), print(Stdout, "{f};") });
    try support.run(named.provide(.{ stdin(Stdin, 9), stdout(Stdout, 4) }), .{io});
    try std.testing.expectEqualStrings("RED;GREEN;BLUE;", Streams.out.text());

    Streams.input = "one\ntwo\n";
    const plain = program(lines(*Io.Reader, 8), .{print(*Io.Writer, "{f}.")});
    try support.run(plain, .{ io, stdin(*Io.Reader, 9), stderr(*Io.Writer, 0) });
    try std.testing.expectEqualStrings("one.two.", Streams.err.text());
}

test "a reader given to run replaces a stdin default, and standard input is not read" {
    const io = Streams.over(std.testing.io, words);
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var reader: Io.Reader = .fixed("in\nmemory");
    const bound = shouted.provide(.{ stdin(Input, 9), stdout(Output, 64) });
    try support.run(bound, .{ io, Input{ .reader = &reader }, Output{ .writer = &writer } });
    try std.testing.expectEqualStrings("IN,MEMORY,", writer.buffered());
    try std.testing.expectEqual(0, Streams.reads);
    try std.testing.expectEqualStrings("", Streams.out.text());
}

/// Reads one line and stops.
const first = program(lines(Input, 8), .{
    take(1),
    map(shout),
    print(Output, "{f},"),
});

test "a stdin binding reads ahead, and runs that read on share a reader of main's" {
    // Each run with a `stdin` of its own: the first one's reader had read
    // `tw` past its line, three bytes at a time, and it is gone with it.
    const io = Streams.over(std.testing.io, "one\ntwo\n");
    try support.run(first, .{ io, stdin(Input, 9), stdout(Output, 64) });
    try support.run(first, .{ io, stdin(Input, 9), stdout(Output, 64) });
    try std.testing.expectEqualStrings("ONE,O,", Streams.out.text());

    // One reader, made as the guide makes it in `main`, given to both.
    _ = Streams.over(std.testing.io, "one\ntwo\n");
    var buffer: [9]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buffer);
    try support.run(first, .{ io, Input{ .reader = &reader.interface }, stdout(Output, 64) });
    try support.run(first, .{ io, Input{ .reader = &reader.interface }, stdout(Output, 64) });
    try std.testing.expectEqualStrings("ONE,TWO,", Streams.out.text());
}

test "a line of standard input that does not fit, and a read that fails" {
    // The buffer has room for the longest line and its newline, and no more.
    const io = Streams.over(std.testing.io, "abcdefgh\nab\n");
    try support.run(shouted, .{ io, stdin(Input, 9), stdout(Output, 64) });
    try std.testing.expectEqualStrings("ABCDEFGH,AB,", Streams.out.text());

    _ = Streams.over(std.testing.io, "ab\nabcdefghi\n");
    try std.testing.expectError(error.StreamTooLong, support.run(shouted, .{ io, stdin(Input, 9), stdout(Output, 64) }));
    try std.testing.expectEqualStrings("AB,", Streams.out.text());

    // As with any reader given to `lines`: the failure has the reader's name for it.
    _ = Streams.over(std.testing.io, words);
    Streams.broken = true;
    try std.testing.expectError(error.ReadFailed, support.run(shouted, .{ io, stdin(Input, 9), stdout(Output, 64) }));
    try std.testing.expectEqualStrings("", Streams.out.text());
}

test "the line of a failed run reaches the standard error the rescue is given" {
    const io = Streams.over(std.testing.io, "ab\nabcdefghi\n");
    var exit: process.Exit = .{};
    shouted.run(.{
        io,
        &exit,
        stdin(Input, 9),
        stdout(Output, 64),
        rescue(process.fail(.{ .status = 2, .prefix = "fatal" })).provide(.{stderr(Stderr, 256)}),
    });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("AB,", Streams.out.text());
    try std.testing.expectEqualStrings("fatal: StreamTooLong\n", Streams.err.text());
}

test "fail takes by name the many errors of a run that opens files" {
    // A file brings dozens of errors, and `fail` takes each by its name:
    // what is left for the run was once computed within the default branch
    // quota, which this run is past.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = Streams.over(std.testing.io, "");
    try tmp.dir.writeFile(io, .{ .sub_path = "taken", .data = "" });
    var path_bytes: [128]u8 = undefined;
    const path = try tmpPath(&path_bytes, &tmp, "taken");

    var exit: process.Exit = .{};
    const copy = program(zrx.fileLines(path, 8), .{zrx.print(Output, "{f}\n")});
    copy.run(.{
        io,
        &exit,
        fileWriter(Output, path, 16, .{ .mode = .create_new }),
        rescue(process.fail(.{})).provide(.{stderr(Stderr, 64)}),
    });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: PathAlreadyExists\n", Streams.err.text());
}

// ---------------------------------------------------------------------------
// A status for an item
// ---------------------------------------------------------------------------

fn isLarge(value: u32) bool {
    return value > 2;
}
fn isOdd(value: u32) bool {
    return value % 2 == 1;
}

test "status raises the status when an item reaches it, and only then" {
    var exit: process.Exit = .{};
    const judged = .{ filter(isLarge), forEach(process.status(3)) };
    program(fromSlice(&few), judged).run(.{&exit});
    try std.testing.expectEqual(0, exit.code);
    program(fromSlice(&many), judged).run(.{&exit});
    try std.testing.expectEqual(3, exit.code);
}

test "status never lowers a status, so two of them say the same in either order" {
    var exit: process.Exit = .{};
    program(fromSlice(&many), .{ tap(process.status(4)), forEach(process.status(2)) }).run(.{&exit});
    try std.testing.expectEqual(4, exit.code);

    exit = .{};
    program(fromSlice(&many), .{ tap(process.status(2)), forEach(process.status(4)) }).run(.{&exit});
    try std.testing.expectEqual(4, exit.code);

    // Nor what something else left there.
    exit = .{ .code = 9 };
    program(fromSlice(&many), .{forEach(process.status(255))}).run(.{&exit});
    try std.testing.expectEqual(255, exit.code);
    program(fromSlice(&many), .{forEach(process.status(1))}).run(.{&exit});
    try std.testing.expectEqual(255, exit.code);
}

test "status on an error path: the run goes on and ends with what was rejected" {
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    const tolerant = program(fromSlice(&many), .{
        recover(error{TooBig}, .{forEach(process.status(1))}),
        map(small),
        forEach(note),
    });
    tolerant.run(.{ &seen, &exit });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqual(3, seen.sum);
}

test "the failure of a run decides the status, whatever an item left" {
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var exit: process.Exit = .{};
    var seen: Seen = .{};
    const judged = program(fromSlice(&many), .{ filter(isOdd), tap(process.status(7)), map(small), forEach(note) });
    judged.run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(process.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());
}
