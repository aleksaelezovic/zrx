const zrx = @import("zrx");
fn effect(_: anytype) void {}
test {
    _ = zrx.batchThen(2, effect);
}
