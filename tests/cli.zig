//! `zrx.ext.cli`: the exit status of a program, and the handler that makes
//! one of the failure of its run.
const std = @import("std");
const zrx = @import("zrx");

const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const map = zrx.map;
const tap = zrx.tap;
const forEach = zrx.forEach;
const rescue = zrx.rescue;
const stderr = zrx.stderr;
const cli = zrx.ext.cli;

const Stderr = zrx.Stderr;

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
fn warn(exit: *cli.Exit, _: u32) void {
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
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&few).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{})) });
    try std.testing.expectEqual(0, exit.code);
    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(3, seen.sum);
}

test "a run that fails leaves status 1 and a line that names the error" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());
    try std.testing.expectEqual(3, seen.sum);
}

test "the status and the prefix are options" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .status = 2, .prefix = "fatal" })) });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("fatal: TooBig\n", writer.buffered());
}

test "without a prefix nothing is written, and no stderr is asked for" {
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, rescue(cli.fail(.{ .status = 3, .prefix = null })) });
    try std.testing.expectEqual(3, exit.code);

    exit = .{};
    seen = .{};
    summed(&few).run(.{ &seen, &exit, rescue(cli.fail(.{ .status = 3, .prefix = null })) });
    try std.testing.expectEqual(0, exit.code);
}

test "a stderr the rescue is given for itself is replaced by one given to run" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    // As a program is written for `main`. Nothing here has an `Io`, so the
    // rescue's own stderr is not acquired.
    const app = summed(&many).provide(.{rescue(cli.fail(.{ .prefix = "fatal" })).provide(.{stderr(256)})});
    app.run(.{ &seen, &exit, Stderr{ .writer = &writer } });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("fatal: TooBig\n", writer.buffered());
}

test "a prefix is written as it is, braces too" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .prefix = "{copy} lines" })) });
    try std.testing.expectEqualStrings("{copy} lines: TooBig\n", writer.buffered());
    try std.testing.expectEqual(1, exit.code);
}

test "the failure's status replaces what a stage left" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    const judged = program(fromSlice(&many), .{ tap(warn), map(small), forEach(note) });
    judged.run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(2, exit.code);
    try std.testing.expectEqualStrings("error: TooBig\n", writer.buffered());

    // And a stage's status stays where the run does not fail.
    exit = .{};
    program(fromSlice(&few), .{ tap(warn), map(small), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(1, exit.code);
}

test "a cancellation is reported like any failure" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    program(fromSlice(&many), .{ map(interrupted), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .status = 130 })) });
    try std.testing.expectEqual(130, exit.code);
    try std.testing.expectEqualStrings("error: Canceled\n", writer.buffered());
}

test "a run that can fail with any error is reported by the name of the one it failed with" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    program(fromSlice(&many), .{ map(unknown), forEach(note) })
        .run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{})) });
    try std.testing.expectEqual(1, exit.code);
    try std.testing.expectEqualStrings("error: Unexpected\n", writer.buffered());
}

test "the status is left also when the line does not fit" {
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{ .status = 2 })) });
    try std.testing.expectEqual(2, exit.code);
}

test "the line is flushed, and a flush that fails is nobody's" {
    // Buffers what it is given and fails when asked to pass it on.
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .{
        .vtable = &.{ .drain = Flushes.drain },
        .buffer = &buffer,
    };
    var exit: cli.Exit = .{};
    var seen: Seen = .{};
    Flushes.count = 0;
    summed(&many).run(.{ &seen, &exit, Stderr{ .writer = &writer }, rescue(cli.fail(.{})) });
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
    var exit: cli.Exit = .{};
    const refusal = cli.fail(.{ .status = 2, .prefix = "fatal" });
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

/// As the guide writes a `main` and what it does about wrong arguments,
/// with the standard error of the process. Compiled, not run.
const fatal = cli.fail(.{ .status = 2, .prefix = "fatal" });

fn refuse(io: std.Io, exit: *cli.Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(256) });
}

fn main(io: std.Io, seen: *Seen, args: []const [:0]const u8) u8 {
    var exit: cli.Exit = .{};
    if (args.len == 0) {
        refuse(io, &exit, error.InvalidArguments);
    } else {
        summed(&many)
            .provide(.{rescue(fatal).provide(.{stderr(256)})})
            .run(.{ io, seen, &exit });
    }
    return exit.code;
}

test "a main with the process's own stderr compiles" {
    _ = &main;
}

test "the arguments of a process are a source as they are" {
    // Nothing of arguments is in the extension: these two are what one writes.
    const Iterated = @TypeOf(zrx.fromIterator(@as(*std.process.Args.Iterator, undefined)));
    try std.testing.expect(Iterated.Item == [:0]const u8);
    const Sliced = @TypeOf(fromSlice(@as([]const [:0]const u8, &.{})));
    try std.testing.expect(Sliced.Item == [:0]const u8);
}
