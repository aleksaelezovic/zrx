const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    zrx.program(http.connections(), .{http.serve(.{http.status(.ok)})})
        .provide(.{http.listen(address, .{ .pending = 0 })})
        .run(.{std.testing.io});
}
