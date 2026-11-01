const zrx = @import("zrx");
test {
    _ = zrx.whenError(u32, zrx.discard());
}
