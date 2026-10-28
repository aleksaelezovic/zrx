const zrx = @import("zrx");

test {
    _ = zrx.tryPipe(@as(u32, 1), .{});
}
