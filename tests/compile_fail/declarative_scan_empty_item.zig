const zrx = @import("zrx");
fn add(state: u64, item: bool) u64 {
    return state + @intFromBool(item);
}
test "scan validates the ordinary item suffix even for empty input" {
    _ = zrx.pipe(zrx.fromSlice(&[_]u32{}), .{zrx.scan(@as(u64, 0), add)});
}
