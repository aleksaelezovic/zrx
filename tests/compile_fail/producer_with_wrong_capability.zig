const zrx = @import("zrx");
fn produce(_: *const u32, _: *zrx.Emitter(u32)) void {}
test {
    const value = true;
    _ = zrx.Stream(u32).fromProducerWith(1, produce, &value);
}
