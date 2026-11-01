const zrx = @import("zrx");
fn identity(value: u32) u32 {
    return value;
}
test {
    _ = zrx.map(.{.{identity}});
}
