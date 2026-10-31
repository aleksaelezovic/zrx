const zrx = @import("zrx");
fn add(_: void, _: u32) void {}
test "scan rejects zero-sized state" {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.scan({}, add)});
}
