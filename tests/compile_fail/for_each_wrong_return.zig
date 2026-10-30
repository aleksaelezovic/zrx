const zrx = @import("zrx");
fn effect(value: u32) u32 {
    return value;
}
test {
    _ = zrx.forEach(effect);
}
