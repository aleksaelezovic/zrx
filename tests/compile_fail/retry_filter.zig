const zrx = @import("zrx");
fn keep(_: u32) bool {
    return true;
}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.filter(keep)}, .{ .max_attempts = 1 });
}
