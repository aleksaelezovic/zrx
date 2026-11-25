const std = @import("std");
const app = @import("app");
const cli = @import("cli");

pub fn main(init: std.process.Init) void {
    cli.main(init, "http-bench", app.serve);
}
