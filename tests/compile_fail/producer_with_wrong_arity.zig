const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
test {
    _ = zrx.Stream(u32).fromProducerWith(1, produce, {});
}
