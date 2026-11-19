const std = @import("std");
const app = @import("app");

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(init.io, err);
    if (args.len != 3) fatal(init.io, error.InvalidArguments);
    app.run(init.io, args[1], args[2]) catch |err| fatal(init.io, err);
}

fn fatal(io: std.Io, err: anyerror) noreturn {
    app.report(io, err);
    std.process.exit(2);
}
