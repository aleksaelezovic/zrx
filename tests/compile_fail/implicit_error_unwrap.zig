const zrx = @import("zrx");

fn checked(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn increment(value: u32) u32 {
    return value + 1;
}

test {
    _ = zrx.pipe(@as(u32, 1), .{zrx.map(.{ checked, increment })});
}
