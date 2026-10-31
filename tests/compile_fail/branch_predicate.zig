const zrx = @import("zrx");
test {
    _ = zrx.when(invalid, zrx.take(1));
}
fn invalid(_: u8) u8 {
    return 1;
}
