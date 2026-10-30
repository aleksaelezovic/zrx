const zrx = @import("zrx");
fn effect(_: u32, _: []const u32) void {}
test {
    _ = zrx.collectThenWith(true, effect);
}
