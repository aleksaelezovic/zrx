const zrx = @import("zrx");
fn produce(_: anytype) void {}
test {
    _ = zrx.Stream(u32).fromProducer(1, produce);
}
