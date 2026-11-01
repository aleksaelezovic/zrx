const zrx = @import("zrx");
fn add(state: u32, item: u32) u32 {
    return state + item;
}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.fold(@as(u32, 0), add)}, .{ .max_attempts = 1 });
}
