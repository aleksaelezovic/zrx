const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) void {
    app.execute(init.gpa, init.io, init.minimal.args) catch |err| switch (err) {
        error.RejectedRecords => std.process.exit(1),
        error.InvalidArguments => std.process.exit(2),
        else => {
            reportFatal(init.io, err);
            std.process.exit(2);
        },
    };
}

fn reportFatal(io: std.Io, err: anyerror) void {
    // execute has already joined users and released resources. Reporting uses
    // no allocator and does not start another run; stderr failures are best-effort.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    writer.interface.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    writer.interface.flush() catch {};
}
