const zrx = @import("zrx");

fn double(value: u32) u32 {
    return value * 2;
}

test {
    _ = zrx.each(.{.{double}});
}
