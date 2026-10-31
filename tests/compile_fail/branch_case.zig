const zrx = @import("zrx");
test {
    _ = zrx.branch(.{zrx.each(identity)});
}
fn identity(value: u8) u8 {
    return value;
}
