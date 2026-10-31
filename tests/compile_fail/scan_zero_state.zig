const zrx = @import("zrx");
fn invalid(_: void, _: u32) void {}
test {
    _ = zrx.scan({}, invalid);
}
