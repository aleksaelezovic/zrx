const zrx = @import("zrx");
fn effect(_: u32) void {}
test {
    _ = zrx.collectThen(effect);
}
