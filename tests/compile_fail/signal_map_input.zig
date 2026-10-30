const zrx = @import("zrx");
fn transform(_: bool) u32 {
    return 1;
}
test {
    const updates = [_]u32{1};
    const current = zrx.pipe(&updates, .{zrx.hold(0)});
    _ = zrx.pipe(&current, .{zrx.map(transform)});
}
