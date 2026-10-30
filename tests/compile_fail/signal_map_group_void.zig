const zrx = @import("zrx");
fn discard(_: u32) void {}
fn constant(_: void) u32 {
    return 1;
}
test {
    const updates = [_]u32{1};
    const current = zrx.pipe(&updates, .{zrx.hold(0)});
    _ = zrx.pipe(&current, .{zrx.map(.{ discard, constant })});
}
