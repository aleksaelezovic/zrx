const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.write(zrx.ext.process.Stdout, "{d}\n")}).run(.{
        std.testing.io,
        zrx.ext.process.stdout(zrx.ext.process.Stdout, 4096),
        zrx.ext.compress.gzipWriter(zrx.ext.process.Stdout, zrx.ext.process.Stdout, .{}),
    });
}
