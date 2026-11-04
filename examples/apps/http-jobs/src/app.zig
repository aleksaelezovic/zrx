const std = @import("std");
const zrx = @import("zrx");
pub const commands = @import("domain/commands.zig");
pub const jobs = @import("domain/jobs.zig");
pub const routes = @import("domain/routes.zig");
pub const store = @import("store.zig");
pub const resources = @import("resources.zig");
pub const composition = @import("composition.zig");
const run = zrx.run;

/// One execution boundary. Everything beyond process capabilities is declared:
/// arguments/configuration, store, listener and its acquisition report.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !void {
    return run(.{
        allocator,
        io,
        resources.configuration(args),
        resources.store(),
        resources.server(.{}),
    }, .{composition.program});
}
