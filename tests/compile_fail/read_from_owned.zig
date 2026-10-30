const std = @import("std");
const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
test {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    _ = zrx.readFrom(std.testing.io, &source);
}
