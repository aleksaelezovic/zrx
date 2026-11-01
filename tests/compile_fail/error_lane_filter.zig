const zrx = @import("zrx");
fn skip(_: zrx.Failure(anyerror)) bool {
    return false;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.branch(.{
        zrx.whenError(anyerror, .{ zrx.filter(skip), zrx.discard() }),
    })});
}
