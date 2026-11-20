const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), zrx.pipe(.{ zrx.route(.{zrx.otherwise(zrx.pipe(.{zrx.debounce(.fromSeconds(1))}))}), zrx.drain() })).run(.{@import("std").testing.io});
}
