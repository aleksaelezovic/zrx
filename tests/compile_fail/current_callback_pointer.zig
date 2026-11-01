const zrx = @import("zrx");
fn identity(value: u32) u32 {
    return value;
}
test {
    const pointer: *const fn (u32) u32 = &identity;
    _ = zrx.map(pointer);
}
