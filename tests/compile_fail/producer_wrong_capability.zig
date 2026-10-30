const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u64)) void {}
test {
    _ = zrx.Stream(u32).fromProducer(1, produce);
}
