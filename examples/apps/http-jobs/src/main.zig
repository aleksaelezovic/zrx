const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        stderr.interface.print("http-jobs: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn execute(init: std.process.Init) !void {
    try app.execute(init.gpa, init.io, init.minimal.args);
    // Successful return means users have joined and managed resources released.
    // Completion reporting must not access the destroyed Store.
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.writeAll("stopped\n");
    try stdout.interface.flush();
}
