const zrx = @import("zrx");

fn add(total: u32, value: u32) error{}!u32 {
    return total + value;
}

test {
    const source = [_]u32{1};
    _ = zrx.pipe(&source, .{ zrx.maxItems(2), zrx.tryFold(0, add) });
}
