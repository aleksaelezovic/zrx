const zrx = @import("zrx");
const source = zrx.fromValue(@as(u32, 1));
fn select(_: u32) *const @TypeOf(source) {
    return &source;
}
test {
    _ = zrx.flatMap(select);
}
