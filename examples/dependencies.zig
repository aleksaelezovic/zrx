//! Dependencies can be passed to `run`, bound to a program, or
//! acquired as a resource with a lifetime. Handlers only name what they need.
const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const rescue = zrx.rescue;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const tap = zrx.tap;
const resource = zrx.resource;
const forEach = zrx.forEach;
const stdout = zrx.stdout;

/// Given to `run`: available to the whole program.
const Logger = struct {
    out: zrx.Stdout,

    fn info(logger: Logger, comptime format: []const u8, args: anytype) !void {
        try logger.out.writer.print("[log] " ++ format ++ "\n", args);
        try logger.out.writer.flush();
    }
};

/// Bound to the program and used by the storage handler.
const Table = struct { name: []const u8 };

/// Acquired when the program starts and released when it ends.
const Database = struct { saved: *u32 };

fn openLogger(out: zrx.Stdout) Logger {
    return .{ .out = out };
}
fn connect(logger: Logger, saved: *u32) !Database {
    try logger.info("database connected", .{});
    return .{ .saved = saved };
}
fn disconnect(logger: Logger, database: Database) void {
    logger.info("database closed after {d} rows", .{database.saved.*}) catch {};
}

fn timesTen(logger: Logger, value: i32) !i32 {
    try logger.info("transforming {d}", .{value});
    return value * 10;
}
fn save(logger: Logger, database: Database, table: Table, value: i32) !void {
    database.saved.* += 1;
    try logger.info("saved {d} to {s}", .{ value, table.name });
}

const Exit = struct { code: u8 = 0 };

/// A run returns nothing: what ends it goes to a rescue, and here becomes
/// the exit status.
fn fail(exit: *Exit, _: anyerror) void {
    exit.code = 1;
}

pub fn main(init: std.process.Init) u8 {
    var exit: Exit = .{};
    var saved: u32 = 0;
    const values = [_]i32{ 5, 12, 19 };

    const app = program(fromSlice(&values), .{
        map(timesTen),
        forEach(save),
    }).provide(.{
        stdout(256),
        resource(openLogger, null),
        resource(connect, disconnect),
        Table{ .name = "measurements" },
    });
    app.run(.{ init.io, &saved, &exit, rescue(fail) });
    return exit.code;
}
