const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), .{}).run(.{});
}
