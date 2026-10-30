const zrx = @import("zrx");
fn effect(_: u32) void {}
test {
    _ = zrx.forEach(@as(*const fn (u32) void, &effect));
}
