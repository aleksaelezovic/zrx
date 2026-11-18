const std = @import("std");
const records = @import("records.zig");
const Io = std.Io;

pub const batch_size = 32;
pub const queue_depth = 4;
pub const output_buffer_bytes = 16 * 1024;
pub const Mode = enum { queued, sync };
const usage = "usage: audit-archive [--sync] INPUT|- OUTPUT\n";

pub fn execute(args_io: Io, args: []const []const u8, comptime run: anytype) !u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        var buffer: [128]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(args_io, &buffer);
        try writer.interface.writeAll(usage);
        try writer.interface.flush();
        return 0;
    }
    const sync = args.len == 3 and std.mem.eql(u8, args[0], "--sync");
    const paths = args[@intFromBool(sync)..];
    if (paths.len != 2) return error.InvalidArguments;
    const stdin = std.mem.eql(u8, paths[0], "-");
    const dir = Io.Dir.cwd();
    const input_file = if (stdin) Io.File.stdin() else try dir.openFile(args_io, paths[0], .{});
    defer if (!stdin) input_file.close(args_io);
    var output_file = try dir.createFileAtomic(args_io, paths[1], .{});
    defer output_file.deinit(args_io);

    var input_buffer: [records.max_line + 1]u8 = undefined;
    var output_buffer: [output_buffer_bytes]u8 = undefined;
    var input = input_file.readerStreaming(args_io, &input_buffer);
    var output = output_file.file.writerStreaming(args_io, &output_buffer);
    try run(args_io, &input.interface, &output.interface, if (sync) .sync else .queued);
    try output_file.link(args_io);
    return 0;
}
