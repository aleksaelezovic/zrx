const zrx = @import("zrx");

test {
    zrx.program(zrx.ext.time.ticks(.fromSeconds(1)), zrx.pipe(.{ zrx.take(1), zrx.drain() })).run(.{});
}
