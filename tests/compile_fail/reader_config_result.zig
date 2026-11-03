const zrx = @import("zrx");
fn config() bool {
    return true;
}
test {
    _ = zrx.reader(config);
}
