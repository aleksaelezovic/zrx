const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.lines(*std.Io.Reader, 8), .{zrx.drain()}).run(.{ std.testing.io, zrx.fileReader(u32, "input.txt", 9) });
}
