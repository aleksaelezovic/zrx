//! `one-billion-rows MEASUREMENTS_FILE`, for either program: the build
//! decides which one `app` is.
const std = @import("std");
const app = @import("app");
const domain = @import("domain");

pub fn main(init: std.process.Init) u8 {
    measure(init) catch |err| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        writer.interface.print("fatal: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        return 2;
    };
    return 0;
}

fn measure(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;
    var stations = try domain.Stations.init(init.gpa);
    defer stations.deinit(init.gpa);
    try app.run(init.io, &stations, args[1]);
}
