const zrx = @import("zrx");
fn inspect(value: error{Bad}!u32) u32 {
    return value catch 0;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(inspect)});
}
