const zrx = @import("zrx");
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.branch(.{
        zrx.whenError(anyerror, .{ zrx.take(0), zrx.discard() }),
    })});
}
