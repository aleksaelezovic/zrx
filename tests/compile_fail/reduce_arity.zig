const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn one(value: u32) u32 {
    return value;
}

test {
    const rows = [_][2]u32{.{ 1, 2 }};
    try program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0, one)), zrx.drain() }).run(.{});
}
