const std = @import("std");
const zrx = @import("zrx");

const Input = struct { reader: *std.Io.Reader };

test {
    zrx.program(zrx.lines(Input, 8), .{zrx.drain()}).run(.{
        std.testing.io,
        zrx.fileReader(Input, "access.log.gz", 4096),
        zrx.ext.compress.gzipReader(Input, Input, 9),
    });
}
