const zrx = @import("zrx");
test {
    _ = zrx.pipe(zrx.fromValue(@as(u8, 1)), .{zrx.flatten()});
}
