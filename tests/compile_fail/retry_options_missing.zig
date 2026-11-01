const zrx = @import("zrx");
fn identity(item: u32) u32 {
    return item;
}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(identity)}, .{ .delay_ms = 0 });
}
