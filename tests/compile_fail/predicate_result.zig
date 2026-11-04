const zrx = @import("zrx");
fn invalid(value: i32) i32 {
    return value;
}
test {
    _ = zrx.all(invalid);
}
