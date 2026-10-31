const zrx = @import("zrx");
test {
    _ = zrx.branch(.{
        zrx.otherwise(zrx.each(identity)),
        zrx.when(matches, zrx.each(identity)),
    });
}
fn matches(_: u8) bool {
    return true;
}
fn identity(value: u8) u8 {
    return value;
}
