const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.ext.fs.entries("src", 0), .{zrx.drain()}).run(.{std.testing.io});
}
