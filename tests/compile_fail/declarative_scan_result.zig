const zrx = @import("zrx");
fn add(state: u64, item: u32) u32 {
    return @intCast(state + item);
}
test "scan requires an exact state result" {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.scan(@as(u64, 0), add)});
}
