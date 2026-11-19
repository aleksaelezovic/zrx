//! The execution boundary: turn arguments into a run and its outcome.
const std = @import("std");
const Io = std.Io;
const zrx = @import("zrx");
pub const commands = @import("domain/commands.zig");
pub const records = @import("domain/records.zig");
pub const summaries = @import("domain/summary.zig");
pub const composition = @import("composition.zig");

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

/// Processes the input `config` names into a new output file. The output is
/// created exclusively: an existing file is never overwritten.
pub fn process(io: Io, config: commands.Config, rules: records.Rules) !summaries.Summary {
    var summary: summaries.Summary = .{};
    const output = zrx.fileWriter(composition.Accepted, config.output, 4096, .{ .mode = .create_new });
    if (config.readsStdin()) {
        try composition.from_stdin.run(.{ io, rules, &summary, output });
    } else {
        // Written before the output, so opened before it: a missing input
        // fails the run while no output file exists yet.
        const input = zrx.fileReader(composition.Input, config.input, records.max_line_bytes + 1);
        try composition.processing.run(.{ io, rules, &summary, input, output });
    }
    return summary;
}

test {
    _ = commands;
    _ = records;
    _ = summaries;
    _ = @import("domain/validation.zig");
}
