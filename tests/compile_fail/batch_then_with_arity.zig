const zrx = @import("zrx");
fn effect(_: []const u32) void {}
test {
    _ = zrx.batchThenWith(2, {}, effect);
}
