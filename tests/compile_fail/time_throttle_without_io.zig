const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), zrx.pipe(.{ zrx.ext.time.throttle(.fromSeconds(1)), zrx.drain() })).run(.{});
}
