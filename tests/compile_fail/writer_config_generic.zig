const zrx = @import("zrx");
fn config(_: anytype) zrx.Writer.Config {
    return .stdout;
}
test {
    _ = zrx.writer(config);
}
