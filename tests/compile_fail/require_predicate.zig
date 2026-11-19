const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn double(value: u32) u32 {
    return value * 2;
}

test {
    try program(range(u32, 0, 3), .{ zrx.map(zrx.require(double, error.Odd)), zrx.drain() }).run(.{});
}
