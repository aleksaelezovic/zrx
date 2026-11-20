const std = @import("std");
const zrx = @import("zrx");

test {
    var slots: [2]u8 = undefined;
    const app = zrx.program(zrx.range(u32, 0, 3), zrx.pipe(.{ zrx.queue(&slots), zrx.drain() }));
    app.run(.{std.testing.io});
}
