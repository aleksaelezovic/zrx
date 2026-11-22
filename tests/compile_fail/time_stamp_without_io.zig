const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), zrx.pipe(.{ zrx.map(zrx.ext.time.stamp(.real)), zrx.drain() })).run(.{});
}
