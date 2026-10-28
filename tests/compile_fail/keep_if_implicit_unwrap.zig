const zrx = @import("zrx");

fn even(value: u32) bool {
    return value % 2 == 0;
}

fn double(value: u32) u32 {
    return value * 2;
}

test {
    _ = zrx.pipe(2, .{ zrx.keepIf(even), zrx.map(double) });
}
