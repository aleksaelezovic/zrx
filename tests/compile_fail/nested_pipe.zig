const zrx = @import("zrx");

fn increment(value: u32) u32 {
    return value + 1;
}

test {
    _ = zrx.pipe(@as(u32, 1), .{ zrx.map(increment), .{zrx.map(increment)} });
}
