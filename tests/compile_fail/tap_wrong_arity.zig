const zrx = @import("zrx");

fn invalid(_: u32, _: u32) void {}

test {
    _ = zrx.tap(invalid);
}
