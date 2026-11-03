const zrx = @import("zrx");
test {
    _ = zrx.pipe(zrx.fromValue(@as([]const u8, "a")), .{
        zrx.splitBy('\n', .{ .max_items = 0 }),
    });
}
