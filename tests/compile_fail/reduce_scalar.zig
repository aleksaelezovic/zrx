const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn sum(total: u32, value: u32) u32 {
    return total + value;
}

test {
    try program(range(u32, 0, 3), .{ zrx.map(zrx.reduce(0, sum)), zrx.drain() }).run(.{});
}
