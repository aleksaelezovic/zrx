//! Command-line policy: what the arguments ask for.
const std = @import("std");

pub const usage =
    \\Usage: record-processor [--input PATH|-] --output NEW_PATH
    \\       record-processor --help
    \\
    \\Normalize identifier,name,amount_cents imports (no header or CSV quoting).
    \\Input defaults to stdin; --input PATH reads a file; --input - selects stdin.
    \\Reads at most 10000 records, each at most 256 bytes, excluding LF.
    \\Writes accepted records to a new file; diagnostics to stderr; summary to stdout.
    \\Exit: 0 accepted all; 1 rejected records; 2 fatal configuration/I/O/limit error.
    \\
;

pub const Config = struct {
    input: []const u8,
    output: []const u8,

    pub fn readsStdin(config: Config) bool {
        return std.mem.eql(u8, config.input, "-");
    }
};

pub const Command = union(enum) {
    help,
    process: Config,

    /// Pure option parsing; argv[0] is not part of this slice.
    pub fn fromArgs(args: []const []const u8) error{InvalidArguments}!Command {
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .help;
        var input: ?[]const u8 = null;
        var output: ?[]const u8 = null;
        var index: usize = 0;
        while (index < args.len) : (index += 2) {
            if (index + 1 >= args.len or args[index + 1].len == 0) return error.InvalidArguments;
            if (std.mem.eql(u8, args[index], "--input") and input == null) {
                input = args[index + 1];
            } else if (std.mem.eql(u8, args[index], "--output") and output == null) {
                output = args[index + 1];
            } else return error.InvalidArguments;
        }
        const config = Config{ .input = input orelse "-", .output = output orelse return error.InvalidArguments };
        if (std.mem.eql(u8, config.output, "-") or std.mem.eql(u8, config.input, config.output))
            return error.InvalidArguments;
        return .{ .process = config };
    }
};

test "default stdin, explicit configuration, help, duplicate and conflicting options" {
    try std.testing.expect((try Command.fromArgs(&.{"--help"})) == .help);
    const defaults = (try Command.fromArgs(&.{ "--output", "out" })).process;
    try std.testing.expectEqualStrings("-", defaults.input);
    try std.testing.expectEqualStrings("out", defaults.output);
    try std.testing.expect(defaults.readsStdin());
    const config = (try Command.fromArgs(&.{ "--output", "out", "--input", "in" })).process;
    try std.testing.expect(!config.readsStdin());
    inline for (.{
        &.{},
        &.{ "--input", "in" },
        &.{ "--help", "--input", "in" },
        &.{ "--input", "in", "--output", "in" },
        &.{ "--input", "in", "--output", "-" },
        &.{ "--input", "in", "--input", "again", "--output", "out" },
        &.{ "--output", "out", "--output", "again" },
        &.{ "--output", "-" },
        &.{ "--input", "in", "--output", "" },
    }) |args| try std.testing.expectError(error.InvalidArguments, Command.fromArgs(args));
}
