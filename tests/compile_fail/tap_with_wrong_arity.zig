const zrx = @import("zrx");

fn effect(_: u32) void {}

test {
    _ = zrx.tapWith(0, effect);
}
