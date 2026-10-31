const zrx = @import("zrx");
fn add(state: error{Failed}!u64, _: u32) error{Failed}!u64 {
    return state;
}
test "scan rejects outer error-union state" {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.scan(@as(error{Failed}!u64, 0), add)});
}
