const std = @import("std");
const zrx = @import("zrx");

const Input = struct { reader: *std.Io.Reader };
const Packed = struct { reader: *std.Io.Reader };

test {
    zrx.program(zrx.lines(Input, 8), .{zrx.drain()}).run(.{zrx.ext.compress.gzipReader(Input, Packed, 9)});
}
