const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) u32 {
    return 1;
}
test {
    _ = zrx.Stream(u32).fromProducer(1, produce);
}
