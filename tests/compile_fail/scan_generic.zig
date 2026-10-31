const zrx = @import("zrx");
fn invalid(state: u32, _: anytype) u32 {
    return state;
}
test {
    _ = zrx.scan(0, invalid);
}
