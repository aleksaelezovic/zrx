const zrx = @import("zrx");
fn invalid(state: u32, comptime value: u32) u32 {
    return state + value;
}
test {
    _ = zrx.scan(0, invalid);
}
