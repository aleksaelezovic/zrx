const zrx = @import("zrx");
fn identity(value: u32) u32 {
    return value;
}
test {
    _ = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{.{zrx.map(identity)}});
}
