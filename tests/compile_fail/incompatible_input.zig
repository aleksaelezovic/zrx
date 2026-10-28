const zrx = @import("zrx");

fn negate(value: bool) bool {
    return !value;
}

test {
    _ = zrx.pipe(@as(u32, 1), .{zrx.map(negate)});
}
