const std = @import("std");
const app = @import("app");
const domain = @import("domain");

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        writer.interface.print("fatal: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn execute(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    if (std.mem.eql(u8, args[1], "--help")) {
        try output.interface.writeAll("usage: one-billion-rows MEASUREMENTS_FILE|-\n");
        try output.interface.flush();
        return;
    }
    const stdin = std.mem.eql(u8, args[1], "-");
    const file = if (stdin) std.Io.File.stdin() else try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer if (!stdin) file.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var input = file.readerStreaming(io, &input_buffer);
    var stations = try domain.Stations.init(init.gpa);
    defer stations.deinit(init.gpa);
    try app.read(&stations, &input.interface);
    try stations.report(init.gpa, &output.interface);
}
