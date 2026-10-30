const zrx = @import("zrx");
fn effect(_: anytype) void {}
test {
    _ = zrx.forEach(effect);
}
