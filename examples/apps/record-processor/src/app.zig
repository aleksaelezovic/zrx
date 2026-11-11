//! The execution boundary: turn arguments into a run and its outcome.
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
pub const commands = @import("domain/commands.zig");
pub const records = @import("domain/records.zig");
pub const summaries = @import("domain/summary.zig");
pub const composition = @import("composition.zig");

const pipe = zrx.pipe;

/// Runs the command `args` describes (without argv[0]). `error.RejectedRecords`
/// and `error.InvalidArguments` are expected outcomes whose output has already
/// been written; `main` owns the exit status for every error.
pub fn execute(io: Io, args: []const []const u8) !void {
    const command = commands.Command.fromArgs(args) catch |err| {
        try reportInvalid(io);
        return err;
    };
    switch (command) {
        .help => try composition.announce(commands.usage).run(.{io}),
        .process => |config| {
            const summary = try process(io, config, .{});
            if (summary.rejected != 0) return error.RejectedRecords;
        },
    }
}

fn reportInvalid(io: Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    try writer.interface.print("fatal: InvalidArguments\n{s}", .{commands.usage});
    try writer.interface.flush();
}

/// Opens the input and creates the output `config` names, then processes.
/// The output is created exclusively: an existing file is never overwritten.
pub fn process(io: Io, config: commands.Config, rules: records.Rules) !summaries.Summary {
    // A line of the maximum length and its LF must fit.
    var input_buffer: [records.max_line_bytes + 1]u8 = undefined;
    const input_file = if (config.readsStdin()) Io.File.stdin() else try Io.Dir.cwd().openFile(io, config.input, .{});
    defer if (!config.readsStdin()) input_file.close(io);
    var input = input_file.readerStreaming(io, &input_buffer);

    const output_file = try Io.Dir.cwd().createFile(io, config.output, .{ .exclusive = true });
    defer output_file.close(io);
    var output_buffer: [4096]u8 = undefined;
    var output = output_file.writer(io, &output_buffer);
    // A successful run has already flushed (and checked it). After a failure
    // this leaves whole records in the file rather than a cut-off buffer.
    defer output.interface.flush() catch {};

    var summary: summaries.Summary = .{};
    const production = zrx.program(zrx.lines(composition.Input), pipe(.{
        zrx.stdout(256),
        zrx.stderr(1024),
        composition.records_pipe,
    }));
    try production.run(.{
        io,
        rules,
        composition.Input{ .reader = &input.interface },
        composition.Accepted{ .writer = &output.interface },
        &summary,
    });
    return summary;
}

test {
    _ = commands;
    _ = records;
    _ = summaries;
    _ = @import("domain/validation.zig");
}
