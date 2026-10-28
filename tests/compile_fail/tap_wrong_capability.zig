const zrx = @import("zrx");

fn effect(_: u32, _: u32) void {}

test {
    _ = zrx.tapWith(true, effect);
}
