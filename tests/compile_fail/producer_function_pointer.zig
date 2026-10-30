const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
test {
    _ = zrx.Stream(u32).fromProducer(
        1,
        @as(*const fn (*zrx.Emitter(u32)) void, &produce),
    );
}
