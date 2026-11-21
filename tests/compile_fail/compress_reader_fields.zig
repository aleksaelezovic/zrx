const std = @import("std");
const zrx = @import("zrx");

const Input = struct { reader: *std.Io.Reader, name: []const u8 };
const Packed = struct { reader: *std.Io.Reader };

test {
    var packed_bytes: std.Io.Reader = .fixed("");
    zrx.program(zrx.lines(Input, 8), .{zrx.drain()}).run(.{
        std.testing.allocator,
        Packed{ .reader = &packed_bytes },
        zrx.ext.compress.zstdReader(Input, Packed, 9, .{}),
    });
}
