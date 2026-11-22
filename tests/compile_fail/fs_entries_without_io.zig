const zrx = @import("zrx");

test {
    zrx.program(zrx.ext.fs.entries("src", 256), .{zrx.drain()}).run(.{});
}
