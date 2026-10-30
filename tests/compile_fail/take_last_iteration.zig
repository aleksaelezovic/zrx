const zrx = @import("zrx");
fn identity(value: u32) u32 {
    return value;
}
test {
    const source = [_]u32{ 1, 2 };
    const tail = zrx.pipe(&source, .{ zrx.takeLast(1), zrx.each(identity) });
    _ = tail.iterator();
}
