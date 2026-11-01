const zrx = @import("zrx");
fn identity(item: u32) u32 {
    return item;
}
fn policy(_: anyerror, _: usize) zrx.RetryDecision {
    return .stop;
}
test {
    const pointer: *const fn (anyerror, usize) zrx.RetryDecision = &policy;
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(identity)}, pointer);
}
