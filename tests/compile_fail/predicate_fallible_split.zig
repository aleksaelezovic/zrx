const zrx = @import("zrx");
fn check(_: u8) error{Failed}!bool {
    return error.Failed;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as([]const u8, "x")), .{
        zrx.splitBy(zrx.all(check), .{ .max_items = 4 }),
    });
}
