const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

test {
    program(range(u32, 0, 3), .{zrx.write(zrx.Stdout, "{d}")}).run(.{});
}
