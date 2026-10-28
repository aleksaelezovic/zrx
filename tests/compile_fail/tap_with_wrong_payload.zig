const zrx = @import("zrx");

fn effect(_: u32, value: u32) error{Failed}!u32 {
    return value;
}

test {
    _ = zrx.tapWith(0, effect);
}
