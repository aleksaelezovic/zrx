//! Bindings and the single public execution boundary; no command effects here.
const std = @import("std");
const zrx = @import("zrx");
pub const domain = @import("domain.zig");
pub const resources = @import("resources.zig");
pub const composition = @import("composition.zig");
const arguments = zrx.arguments;
const run = zrx.run;

/// Propagate the pipeline outcome. main alone decides diagnostics and OS exit.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) anyerror!void {
    return run(.{
        allocator,
        io,
        arguments(args),
        resources.command(),
        resources.checkoutStorage(),
        resources.consoleOutput(),
        resources.diagnosticOutput(),
    }, .{composition.commandFlow});
}
