const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn wide(total: u64, value: u64) u64 {
    return total + value;
}

test {
    const rows = [_][2]u32{.{ 1, 2 }};
    program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0, wide)), zrx.drain() }).run(.{});
}
