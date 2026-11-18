const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const mergeTagged = zrx.mergeTagged;

const Side = enum { left, right };

test {
    const sources = mergeTagged(Side, .{ .left = range(u32, 0, 3), .right = range(u32, 0, 3), .middle = range(u32, 0, 3) });
    try program(sources, .{zrx.drain()}).run(.{std.testing.io});
}
