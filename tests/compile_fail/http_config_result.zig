const zrx = @import("zrx");
fn config() u16 {
    return 0;
}
test {
    _ = zrx.httpServer(config);
}
