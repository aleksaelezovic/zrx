const zrx = @import("zrx");

fn boolean(value: bool) bool {
    return value;
}

test {
    _ = zrx.tryPipe(@as(u32, 1), .{zrx.map(boolean)});
}
