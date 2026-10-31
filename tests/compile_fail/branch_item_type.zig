const zrx = @import("zrx");
test {
    const input = [_]u8{1};
    _ = zrx.pipe(zrx.fromSlice(&input), .{zrx.branch(.{
        zrx.when(matches, zrx.each(small)),
        zrx.otherwise(zrx.each(big)),
    })});
}
fn matches(_: u8) bool {
    return true;
}
fn small(value: u8) u16 {
    return value;
}
fn big(value: u8) u32 {
    return value;
}
