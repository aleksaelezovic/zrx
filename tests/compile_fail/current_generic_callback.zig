const zrx = @import("zrx");
fn identity(value: anytype) @TypeOf(value) {
    return value;
}
test {
    _ = zrx.map(identity);
}
