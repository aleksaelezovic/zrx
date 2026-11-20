const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const mergeTagged = zrx.mergeTagged;

const Input = union(enum) { count: u32, word: []const u8 };

test {
    program(mergeTagged(Input, .{ .count = range(u32, 0, 3), .word = range(u8, 0, 3) }), .{zrx.drain()}).run(.{std.testing.io});
}
