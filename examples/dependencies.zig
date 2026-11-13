//! Dependencies at two levels: given to `run`, and provided inside a pipe.
//! Handlers only name what they need.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const provide = zrx.provide;
const subscribe = zrx.subscribe;

/// Given to `run`: available to the whole program.
const Logger = struct {
    writer: *std.Io.Writer,

    fn info(logger: Logger, comptime format: []const u8, args: anytype) !void {
        try logger.writer.print("[log] " ++ format ++ "\n", args);
    }
};

/// Provided inside the pipe: only the storage stage knows about it.
const Table = struct { name: []const u8 };

fn timesTen(logger: Logger, value: i32) !i32 {
    try logger.info("transforming {d}", .{value});
    return value * 10;
}
fn save(logger: Logger, saved: *u32, table: Table, value: i32) !void {
    saved.* += 1;
    try logger.info("saved {d} to {s}", .{ value, table.name });
}

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const logger: Logger = .{ .writer = &stdout.interface };

    var saved: u32 = 0;
    const values = [_]i32{ 5, 12, 19 };

    const storage = pipe(.{
        provide(Table{ .name = "measurements" }),
        subscribe(save),
    });
    const app = program(fromSlice(&values), pipe(.{
        map(timesTen),
        storage,
    }));
    try app.run(.{ logger, &saved });

    try logger.info("{d} rows", .{saved});
    try stdout.interface.flush();
}
