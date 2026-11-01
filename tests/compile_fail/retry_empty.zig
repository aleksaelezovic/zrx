const zrx = @import("zrx");
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{}, .{ .max_attempts = 1 });
}
