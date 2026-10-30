const zrx = @import("zrx");
fn produce(_: *const u32, _: *zrx.Emitter(u32)) void {}
test {
    const value: u32 = 1;
    _ = zrx.Stream(u32).fromProducerWith(
        1,
        @as(*const fn (*const u32, *zrx.Emitter(u32)) void, &produce),
        &value,
    );
}
