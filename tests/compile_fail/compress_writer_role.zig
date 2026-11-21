const std = @import("std");
const zrx = @import("zrx");

const Output = struct { writer: *std.Io.Writer };

test {
    // The second argument is the role of the compressed bytes, not a path.
    zrx.program(zrx.range(u32, 0, 3), .{zrx.write(Output, "{d}\n")}).run(.{zrx.ext.compress.gzipWriter(Output, []const u8, .{})});
}
