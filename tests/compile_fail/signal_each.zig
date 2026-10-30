const zrx = @import("zrx");
fn double(value: u32) u32 {
    return value * 2;
}
test {
    const updates = [_]u32{1};
    const current = zrx.pipe(&updates, .{zrx.hold(0)});
    _ = zrx.pipe(&current, .{zrx.each(double)});
}
