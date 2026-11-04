const zrx = @import("zrx");
fn positive(value: i32) bool {
    return value > 0;
}
test {
    _ = zrx.all(&positive);
}
