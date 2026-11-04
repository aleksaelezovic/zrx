const std = @import("std");
const zrx = @import("zrx");
const Settings = struct { port: u16 };
fn config(settings: Settings) zrx.HttpServerConfig {
    return .{ .address = .{ .ip4 = .loopback(settings.port) } };
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io, zrx.httpServer(config) }, .{
        zrx.pipe(zrx.httpRequests(*zrx.HttpServer), .{zrx.discard()}),
    });
}
