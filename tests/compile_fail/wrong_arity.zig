const zrx = @import("zrx");

fn add(left: u32, right: u32) u32 {
    return left + right;
}

test {
    _ = zrx.map(.{add});
}
