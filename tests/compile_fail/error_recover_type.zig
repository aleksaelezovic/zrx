const zrx = @import("zrx");
fn replace(_: error{Bad}) u64 {
    return 1;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.recover(replace)});
}
