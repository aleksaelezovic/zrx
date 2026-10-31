const zrx = @import("zrx");
fn add(state: u32, value: u32) u32 {
    return state + value;
}
fn identity(value: u32) u32 {
    return value;
}
test {
    const totals = zrx.pipe(&[_]u32{1}, .{ zrx.scan(0, add), zrx.each(identity) });
    _ = totals.iterator();
}
