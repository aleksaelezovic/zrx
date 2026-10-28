const zrx = @import("zrx");

fn invalid(value: bool) bool {
    return value;
}

test {
    const values = [_]u32{ 1, 2 };
    _ = zrx.pipe(&values, .{zrx.filter(invalid)});
}
