const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
fn select(_: u32) @TypeOf(zrx.Stream(u32).fromProducer(1, produce)) {
    return zrx.Stream(u32).fromProducer(1, produce);
}
test {
    _ = zrx.flatMap(select);
}
