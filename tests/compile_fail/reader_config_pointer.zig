const zrx = @import("zrx");
fn config() zrx.Reader.Config {
    return .stdin;
}
test {
    _ = zrx.reader(@as(*const fn () zrx.Reader.Config, &config));
}
