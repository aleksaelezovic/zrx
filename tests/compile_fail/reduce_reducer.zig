const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn isLarger(total: u32, value: u32) bool {
    return value > total;
}

test {
    const rows = [_][2]u32{.{ 1, 2 }};
    try program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0, isLarger)), zrx.drain() }).run(.{});
}
