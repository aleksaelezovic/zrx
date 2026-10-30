const zrx = @import("zrx");
fn produce(_: *const u32, _: *zrx.Emitter(u32)) u32 {
    return 1;
}
test {
    const value: u32 = 1;
    _ = zrx.Stream(u32).fromProducerWith(1, produce, &value);
}
