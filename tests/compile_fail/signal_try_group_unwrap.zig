const zrx = @import("zrx");
fn checked(value: u32) error{Bad}!u32 {
    return value;
}
fn plain(value: u32) u32 {
    return value;
}
test {
    const updates = [_]u32{1};
    const current = zrx.pipe(&updates, .{zrx.hold(0)});
    _ = try zrx.tryPipe(&current, .{zrx.map(.{ checked, plain })});
}
