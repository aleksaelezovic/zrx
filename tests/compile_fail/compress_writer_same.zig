const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.write(zrx.Stdout, "{d}\n")}).run(.{
        std.testing.io,
        zrx.stdout(4096),
        zrx.ext.compress.gzipWriter(zrx.Stdout, zrx.Stdout, .{}),
    });
}
