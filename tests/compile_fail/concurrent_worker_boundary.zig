const std = @import("std");
const zrx = @import("zrx");

test {
    try zrx.program(zrx.range(u32, 0, 3), .{zrx.concurrent(2, .{ zrx.queue(2), zrx.drain() })}).run(.{std.testing.io});
}
