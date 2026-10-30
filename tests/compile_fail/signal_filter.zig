const zrx = @import("zrx");
fn keep(_: u32) bool {
    return true;
}
test {
    const updates = [_]u32{1};
    const current = zrx.pipe(&updates, .{zrx.hold(0)});
    _ = zrx.pipe(&current, .{zrx.filter(keep)});
}
