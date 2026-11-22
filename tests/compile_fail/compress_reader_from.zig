const std = @import("std");
const zrx = @import("zrx");

const Input = struct { reader: *std.Io.Reader };

test {
    // The second argument is the role of the compressed bytes, not a path.
    zrx.program(zrx.lines(Input, 8), .{zrx.drain()}).run(.{zrx.ext.compress.zlibReader(Input, []const u8, 9)});
}
