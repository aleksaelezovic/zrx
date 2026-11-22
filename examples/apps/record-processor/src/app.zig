//! The execution boundary: turn arguments into a run and its outcome.
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
pub const commands = @import("domain/commands.zig");
pub const records = @import("domain/records.zig");
pub const summaries = @import("domain/summary.zig");
pub const composition = @import("composition.zig");

const streams = zrx.ext.process;
const Diagnostics = composition.Diagnostics;

/// How the app ended, for `main` to return: 0, 1 when records were
/// rejected, 2 for everything that ended a run or kept one from starting.
pub const Exit = streams.Exit;

/// Whatever ends a run: one best-effort line on stderr, exit status 2.
const fatal = streams.fail(.{ .status = 2, .prefix = "fatal" });

/// The same line and status for what fails before there is a run: a
/// program of one item, the failure.
pub fn refuse(io: Io, exit: *Exit, err: anyerror) void {
    zrx.program(zrx.fromValue(err), .{zrx.forEach(fatal)}).run(.{ io, exit, streams.stderr(Diagnostics, 256) });
}

/// Arguments that describe no command: the same line, then the usage.
fn invalid(diagnostics: Diagnostics, exit: *Exit, usage: []const u8) void {
    exit.code = 2;
    diagnostics.writer.print("fatal: InvalidArguments\n{s}", .{usage}) catch return;
    diagnostics.writer.flush() catch {};
}

/// Runs the command `args` describes (without argv[0]) and leaves the
/// status in `exit`. A run returns nothing: what fails one goes to `fatal`.
pub fn execute(io: Io, args: []const []const u8, exit: *Exit) void {
    const command = commands.Command.fromArgs(args) catch {
        return zrx.program(zrx.fromValue(commands.usage), .{zrx.forEach(invalid)}).run(.{ io, exit, streams.stderr(Diagnostics, 1024) });
    };
    switch (command) {
        .help => composition.announce(commands.usage).run(.{ io, exit, zrx.rescue(fatal).provide(.{streams.stderr(Diagnostics, 256)}) }),
        .process => |config| process(io, config, .{}, exit),
    }
}

/// Processes the input `config` names, a file or standard input, into a new
/// output file. The input is opened first: a missing input leaves no output
/// file behind. It is read on from where its descriptor stands, so a path
/// such as `/dev/fd/0` continues what read it before. The output is created
/// exclusively: an existing file is never overwritten. A rejected record
/// leaves status 1, unless the run itself failed.
pub fn process(io: Io, config: commands.Config, rules: records.Rules, exit: *Exit) void {
    // A line of the maximum length and its LF must fit.
    var buffer: [records.max_line_bytes + 1]u8 = undefined;
    const file = if (config.readsStdin()) Io.File.stdin() else Io.Dir.cwd().openFile(io, config.input, .{}) catch |err| return refuse(io, exit, err);
    defer if (!config.readsStdin()) file.close(io);
    var input = file.readerStreaming(io, &buffer);

    composition.processing.run(.{
        io,
        rules,
        exit,
        zrx.rescue(fatal).provide(.{streams.stderr(Diagnostics, 256)}),
        composition.Input{ .reader = &input.interface },
        zrx.ext.fs.fileWriter(composition.Accepted, config.output, 4096, .{ .mode = .create_new }),
    });
}

test {
    _ = commands;
    _ = records;
    _ = summaries;
    _ = @import("domain/validation.zig");
}
