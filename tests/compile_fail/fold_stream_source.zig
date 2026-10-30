const zrx = @import("zrx");

fn add(total: u32, value: u32) u32 {
    return total + value;
}

test {
    var source: zrx.Stream(u32) = undefined;
    _ = zrx.pipe(&source, .{zrx.fold(0, add)});
}
