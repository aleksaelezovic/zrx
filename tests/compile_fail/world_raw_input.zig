const zrx = @import("zrx");
fn double(value: u32) u32 {
    return value * 2;
}
test "raw values are not an eager pipeline entry point" {
    _ = zrx.pipe(@as(u32, 3), .{zrx.map(double)});
}
