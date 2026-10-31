const zrx = @import("zrx");
fn add(state: u64, item: u32) u64 {
    return state + item;
}
test "scan requires explicit values for a signal" {
    const signal = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.hold(@as(u32, 0))});
    _ = zrx.pipe(&signal, .{zrx.scan(@as(u64, 0), add)});
}
