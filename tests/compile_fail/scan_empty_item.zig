const zrx = @import("zrx");
fn invalid(state: u32, value: bool) u32 {
    return state + @intFromBool(value);
}
test {
    _ = zrx.pipe(&[_]u32{}, .{zrx.scan(0, invalid)});
}
