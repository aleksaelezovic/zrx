const zrx = @import("zrx");
fn delimiter(_: u8) error{Bad}!bool {
    return false;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as([]const u8, "a")), .{
        zrx.splitBy(delimiter, .{ .max_items = 8 }),
    });
}
