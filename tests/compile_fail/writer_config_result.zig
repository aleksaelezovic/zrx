const zrx = @import("zrx");
fn config() zrx.Reader.Config {
    return .stdin;
}
test {
    _ = zrx.writer(config);
}
