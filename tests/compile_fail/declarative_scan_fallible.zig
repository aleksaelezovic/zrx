const zrx = @import("zrx");
fn add(state: u64, item: u32) error{Failed}!u64 {
    return state + item;
}
test "scan does not accept fallible reducers" {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.scan(@as(u64, 0), add)});
}
