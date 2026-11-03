const zrx = @import("zrx");
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{@as(u8, 1)});
}
