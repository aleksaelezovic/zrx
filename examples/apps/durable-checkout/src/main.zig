const std = @import("std");
const app = @import("checkout");

pub fn main(init: std.process.Init) void {
    app.execute(init.gpa, init.io, init.minimal.args) catch |err| {
        // Invalid usage was already delivered by its command terminal.
        if (err == error.InvalidArguments) std.process.exit(2);
        // All users have joined and resources have released. Fatal reporting
        // is best-effort, allocation-free, and never starts a second run.
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "error: {s}\n", .{@errorName(err)}) catch unreachable;
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(if (err == error.Conflict) 3 else 1);
    };
}
