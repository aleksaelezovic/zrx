const std = @import("std");
const zrx = @import("zrx");
pub const records = @import("domain/records.zig");
pub const composition = @import("composition.zig");
pub const commands = @import("domain/commands.zig");
pub const resources = @import("resources.zig");
const run = zrx.run;

/// Propagate the pipeline outcome; main owns diagnostics and OS exit policy.
pub fn execute(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) anyerror!void {
    return run(.{
        allocator,
        io,
        records.Rules{},
        zrx.arguments(args),
        resources.command(),
        resources.input(),
        resources.acceptedOutput(),
        resources.diagnosticOutput(),
        resources.consoleOutput(),
    }, .{composition.commandFlow});
}

test {
    _ = records;
    _ = commands;
    _ = @import("domain/validation.zig");
    _ = @import("domain/summary.zig");
    _ = @import("domain/reporting.zig");
}
