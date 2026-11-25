const std = @import("std");
const plain = @import("plain");
const cli = @import("cli");

pub fn main(init: std.process.Init) void {
    cli.main(init, "http-bench-zig", plain.listen);
}
