const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.concurrent(2, .{zrx.drain()})}).run(.{});
}
