const zrx = @import("zrx");
fn ignore(_: u32) void {}
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.forEach(ignore)}, .{ .max_attempts = 1 });
}
