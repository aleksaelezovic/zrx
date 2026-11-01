const zrx = @import("zrx");
fn replace(_: u32) u32 {
    return 1;
}
test {
    _ = zrx.recover(replace);
}
