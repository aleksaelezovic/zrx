const zrx = @import("zrx");
fn identity(item: u32) u32 {
    return item;
}
test {
    _ = zrx.retryPipe(@as(u32, 1), .{zrx.map(identity)}, .{ .max_attempts = 1 });
}
