const std = @import("std");
const zrx = @import("zrx");
const Service = struct { value: u32 };
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{
        zrx.pipe(zrx.fromService(Service), .{zrx.discard()}),
    });
}
