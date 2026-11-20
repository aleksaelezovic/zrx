//! The execution boundary: turn arguments into a run and its outcome.
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
pub const commands = @import("domain/commands.zig");
pub const records = @import("domain/records.zig");
pub const summaries = @import("domain/summary.zig");
pub const composition = @import("composition.zig");

/// How the app ended, for `main` to return: 0, 1 when records were
/// rejected, 2 for everything that ended a run or kept one from starting.
pub const Exit = struct { code: u8 = 0 };

/// Whatever ends a run: one best-effort line on stderr, exit status 2.
fn fatal(diagnostics: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.code = 2;
    diagnostics.writer.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    diagnostics.writer.flush() catch {};
}

/// The same line and status for what fails before there is a run: a
/// program of one item, the failure.
pub fn refuse(io: Io, exit: *Exit, err: anyerror) void {
    zrx.program(zrx.fromValue(err), .{zrx.forEach(fatal)}).run(.{ io, exit, zrx.stderr(256) });
}

/// Arguments that describe no command: the same line, then the usage.
fn invalid(diagnostics: zrx.Stderr, exit: *Exit, usage: []const u8) void {
    exit.code = 2;
    diagnostics.writer.print("fatal: InvalidArguments\n{s}", .{usage}) catch return;
    diagnostics.writer.flush() catch {};
}

/// Runs the command `args` describes (without argv[0]) and leaves the
/// status in `exit`. A run returns nothing: what fails one goes to `fatal`.
pub fn execute(io: Io, args: []const []const u8, exit: *Exit) void {
    const command = commands.Command.fromArgs(args) catch {
        return zrx.program(zrx.fromValue(commands.usage), .{zrx.forEach(invalid)}).run(.{ io, exit, zrx.stderr(1024) });
    };
    switch (command) {
        .help => composition.announce(commands.usage).run(.{ io, exit, zrx.stderr(256), zrx.rescue(fatal) }),
        .process => |config| process(io, config, .{}, exit),
    }
}

/// Opens the input `config` names and processes it into a new output file.
/// The output is created exclusively: an existing file is never overwritten.
/// Rejected records make the status 1, unless the run itself failed.
pub fn process(io: Io, config: commands.Config, rules: records.Rules, exit: *Exit) void {
    // A line of the maximum length and its LF must fit.
    var input_buffer: [records.max_line_bytes + 1]u8 = undefined;
    const input_file = if (config.readsStdin()) Io.File.stdin() else Io.Dir.cwd().openFile(io, config.input, .{}) catch |err| return refuse(io, exit, err);
    defer if (!config.readsStdin()) input_file.close(io);
    var input = input_file.readerStreaming(io, &input_buffer);

    var summary: summaries.Summary = .{};
    const production = zrx.program(zrx.lines(composition.Input, records.max_line_bytes), composition.records_pipe).provide(.{
        zrx.stdout(256),
        zrx.stderr(1024),
        zrx.rescue(fatal),
        zrx.fileWriter(composition.Accepted, config.output, 4096, .{ .mode = .create_new }),
    });
    production.run(.{
        io,
        rules,
        composition.Input{ .reader = &input.interface },
        &summary,
        exit,
    });
    if (exit.code == 0 and summary.rejected != 0) exit.code = 1;
}

test {
    _ = commands;
    _ = records;
    _ = summaries;
    _ = @import("domain/validation.zig");
}
