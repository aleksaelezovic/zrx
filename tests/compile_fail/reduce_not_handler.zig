const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

test {
    const rows = [_][2]u32{.{ 1, 2 }};
    program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0, 1)), zrx.drain() }).run(.{});
}
