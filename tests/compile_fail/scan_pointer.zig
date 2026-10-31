const zrx = @import("zrx");
fn add(state: u32, value: u32) u32 {
    return state + value;
}
test {
    const callback: *const fn (u32, u32) u32 = &add;
    _ = zrx.scan(0, callback);
}
