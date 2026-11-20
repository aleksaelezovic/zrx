const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

// A reducer is given the state and the item; `require` checks one item.
test {
    program(range(u32, 0, 3), .{ zrx.fold(@as(u32, 0), zrx.require(isEven, error.Odd)), zrx.drain() }).run(.{});
}
