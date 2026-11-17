const zrx = @import("zrx");

test {
    try zrx.program(zrx.range(u32, 0, 3), .{}).run(.{});
}
