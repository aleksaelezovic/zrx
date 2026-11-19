const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

test {
    try program(range(u32, 0, 3), .{ zrx.map(zrx.require(true, error.Odd)), zrx.drain() }).run(.{});
}
