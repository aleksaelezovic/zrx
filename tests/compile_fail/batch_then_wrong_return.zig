const zrx = @import("zrx");
fn effect(_: []const u32) u32 {
    return 0;
}
test {
    _ = zrx.batchThen(2, effect);
}
