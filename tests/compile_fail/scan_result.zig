const zrx = @import("zrx");
fn invalid(state: u32, value: u32) u64 {
    return @as(u64, state) + value;
}
test {
    _ = zrx.scan(0, invalid);
}
