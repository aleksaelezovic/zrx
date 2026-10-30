const zrx = @import("zrx");
fn effect(_: u32, _: u32) void {}
test {
    const values = [_]u32{1};
    zrx.pipe(&values, .{zrx.forEachWith(true, effect)});
}
