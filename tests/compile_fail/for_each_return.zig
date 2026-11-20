const zrx = @import("zrx");

fn echo(value: u32) u32 {
    return value;
}

test {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.forEach(echo)}).run(.{});
}
