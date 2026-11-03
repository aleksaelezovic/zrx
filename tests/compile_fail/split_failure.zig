const zrx = @import("zrx");
const Failure = zrx.Failure(error{Bad});
fn delimiter(_: Failure) bool {
    return true;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as([]const Failure, &.{})), .{
        zrx.splitBy(delimiter, .{ .max_items = 8 }),
    });
}
