const std = @import("std");
const zrx = @import("zrx");
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{
        zrx.pipe(zrx.httpRequests(*zrx.HttpServer), .{zrx.discard()}),
    });
}
