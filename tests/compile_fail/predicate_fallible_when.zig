const zrx = @import("zrx");
fn check(_: i32) error{Failed}!bool {
    return error.Failed;
}
test {
    _ = zrx.when(zrx.any(check), zrx.discard());
}
