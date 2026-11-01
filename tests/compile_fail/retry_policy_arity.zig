const zrx = @import("zrx");
fn identity(item: u32) error{Failed}!u32 {
    return item;
}
fn policy(_: error{Failed}) zrx.RetryDecision {
    return .stop;
}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(identity)}, policy);
}
