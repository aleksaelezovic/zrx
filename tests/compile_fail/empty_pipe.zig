const zrx = @import("zrx");

test {
    _ = zrx.pipe(@as(u32, 1), .{});
}
