const zrx = @import("zrx");
fn invalid(value: u32) u32 {
    return value;
}
test {
    _ = zrx.scan(0, invalid);
}
