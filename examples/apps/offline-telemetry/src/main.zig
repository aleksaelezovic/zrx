const std = @import("std");
const zrx = @import("zrx");
const app = @import("app");

const failure = zrx.pipe(.{zrx.print(zrx.Stderr, "fatal: {s}\n")});

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| fatal(init.io, err);
    app.execute(init.io, args[1..]) catch |err| fatal(init.io, err);
}

/// Every failure: one best-effort line on stderr, exit status 2.
fn fatal(io: std.Io, err: anyerror) noreturn {
    zrx.program(zrx.fromValue(@errorName(err)), failure).provide(.{zrx.stderr(256)}).run(.{io}) catch {};
    std.process.exit(2);
}
