const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(init.io, err);
    app.execute(init.io, args[1..]) catch |err| switch (err) {
        error.RejectedRecords => std.process.exit(1),
        error.InvalidArguments => std.process.exit(2),
        else => fatal(init.io, err),
    };
}

/// Everything else: one best-effort line on stderr, exit status 2.
fn fatal(io: std.Io, err: anyerror) noreturn {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    writer.interface.print("fatal: {s}\n", .{@errorName(err)}) catch {};
    writer.interface.flush() catch {};
    std.process.exit(2);
}
