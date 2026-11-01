const zrx = @import("zrx");
fn identity(item: u32) error{Failed}!u32 {
    return item;
}
fn policy(_: error{Failed}, _: usize) ?u64 {
    return null;
}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(identity)}, policy);
}
