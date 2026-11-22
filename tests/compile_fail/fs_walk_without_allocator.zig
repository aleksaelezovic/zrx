const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.ext.fs.walk("src", 256), .{zrx.drain()}).run(.{std.testing.io});
}
