const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.ext.fs.walk("src", 0, 16), .{zrx.drain()}).run(.{std.testing.io});
}
