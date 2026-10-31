const zrx = @import("zrx");
fn invalid(state: u32, value: u32) error{Overflow}!u32 {
    return state + value;
}
test {
    _ = zrx.scan(0, invalid);
}
