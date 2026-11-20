const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const mergeTagged = zrx.mergeTagged;

const Both = union(enum) { left: u32, right: u32 };

test {
    program(mergeTagged(Both, .{ .left = range(u32, 0, 3), .right = range(u32, 0, 3) }), .{zrx.drain()}).run(.{std.testing.io});
}
