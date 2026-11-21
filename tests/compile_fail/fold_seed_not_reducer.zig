const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

// A handler of one item is no reducer, and says so before the seed is looked at.
test {
    program(range(u32, 0, 3), .{ zrx.fold(0, zrx.require(isEven, error.Odd)), zrx.drain() }).run(.{});
}
