const zrx = @import("zrx");
fn select(_: u32) u32 {
    return 1;
}
test {
    _ = zrx.flatMap(select);
}
