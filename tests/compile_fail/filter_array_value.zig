const zrx = @import("zrx");

fn even(value: u32) bool {
    return value % 2 == 0;
}

test {
    _ = zrx.pipe([_]u32{ 1, 2 }, .{zrx.filter(even)});
}
