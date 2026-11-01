const zrx = @import("zrx");
fn replace(_: error{Bad}) error{Again}!u32 {
    return error.Again;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.recover(replace)});
}
