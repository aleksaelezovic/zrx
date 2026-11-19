const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn isEven(value: u64) bool {
    return value % 2 == 0;
}

test {
    try program(range(u32, 0, 3), .{ zrx.map(zrx.require(isEven, error.Odd)), zrx.drain() }).run(.{});
}
