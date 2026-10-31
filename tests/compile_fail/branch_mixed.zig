const zrx = @import("zrx");
test {
    const input = [_]u8{1};
    _ = zrx.pipe(zrx.fromSlice(&input), .{zrx.branch(.{
        zrx.when(matches, zrx.each(identity)),
        zrx.otherwise(zrx.forEach(ignore)),
    })});
}
fn matches(_: u8) bool {
    return true;
}
fn identity(value: u8) u8 {
    return value;
}
fn ignore(_: u8) void {}
