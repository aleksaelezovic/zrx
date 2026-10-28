const zrx = @import("zrx");

fn increment(value: u32) u32 {
    return value + 1;
}

test {
    _ = zrx.map(.{ increment, .{increment} });
}
