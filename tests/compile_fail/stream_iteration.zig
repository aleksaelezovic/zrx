const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
fn double(value: u32) u32 {
    return value * 2;
}
test {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    _ = zrx.pipe(&source, .{zrx.each(double)}).iterator();
}
