const zrx = @import("zrx");
fn identity(value: u32) u32 {
    return value;
}
test {
    const values = [_]u32{1};
    const input = zrx.merge(.{&values});
    _ = zrx.pipe(&input, .{zrx.each(identity)}).iterator();
}
