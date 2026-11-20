const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

// The error itself is wanted, `error.Odd`, not the set it belongs to.
test {
    program(range(u32, 0, 3), .{ zrx.map(zrx.require(isEven, error{Odd})), zrx.drain() }).run(.{});
}
