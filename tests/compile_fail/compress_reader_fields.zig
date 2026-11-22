const std = @import("std");
const zrx = @import("zrx");

const Input = struct { reader: *std.Io.Reader, name: []const u8 };
const Packed = struct { reader: *std.Io.Reader };

test {
    var packed_bytes: std.Io.Reader = .fixed("");
    var window: [std.compress.zstd.block_size_max + 1024]u8 = undefined;
    zrx.program(zrx.lines(Input, 8), .{zrx.drain()}).run(.{
        Packed{ .reader = &packed_bytes },
        zrx.ext.compress.zstdReader(Input, Packed, 9, &window),
    });
}
