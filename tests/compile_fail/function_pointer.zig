const zrx = @import("zrx");

fn increment(value: u32) u32 {
    return value + 1;
}

test {
    const transform: *const fn (u32) u32 = &increment;
    _ = zrx.map(transform);
}
