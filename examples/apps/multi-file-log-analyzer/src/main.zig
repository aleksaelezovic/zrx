const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(init.io, err);
    app.execute(init.io, args[1..]) catch |err| fatal(init.io, err);
}

/// One best-effort line on stderr, exit status 2.
fn fatal(io: std.Io, err: anyerror) noreturn {
    app.report(io, err);
    std.process.exit(2);
}
