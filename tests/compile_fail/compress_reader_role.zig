const std = @import("std");
const zrx = @import("zrx");

const Packed = struct { reader: *std.Io.Reader };

test {
    var packed_bytes: std.Io.Reader = .fixed("");
    zrx.program(zrx.lines(*std.Io.Reader, 8), .{zrx.drain()}).run(.{ Packed{ .reader = &packed_bytes }, zrx.ext.compress.gzipReader(u32, Packed, 9) });
}
