const zrx = @import("zrx");
fn config() zrx.HttpServerConfig {
    return .{ .address = .{ .ip4 = .loopback(0) } };
}
test {
    _ = zrx.httpServer(&config);
}
