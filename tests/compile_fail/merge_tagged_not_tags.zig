const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const mergeTagged = zrx.mergeTagged;

test {
    try program(mergeTagged(u32, .{ .left = range(u32, 0, 3) }), .{zrx.drain()}).run(.{});
}
