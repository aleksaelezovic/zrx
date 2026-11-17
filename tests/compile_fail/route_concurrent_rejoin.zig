const std = @import("std");
const zrx = @import("zrx");

test {
    try zrx.program(zrx.range(u32, 0, 3), .{ zrx.route(.{zrx.otherwise(.{zrx.concurrent(2, .{zrx.take(1)})})}), zrx.drain() }).run(.{std.testing.io});
}
