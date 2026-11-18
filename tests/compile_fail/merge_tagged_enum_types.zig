const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const mergeTagged = zrx.mergeTagged;

const Side = enum { left, right };

test {
    try program(mergeTagged(Side, .{ .left = range(u32, 0, 3), .right = range(u8, 0, 3) }), .{zrx.drain()}).run(.{std.testing.io});
}
