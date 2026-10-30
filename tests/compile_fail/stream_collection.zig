const zrx = @import("zrx");
fn produce(_: *zrx.Emitter(u32)) void {}
test {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    var buffer: [1]u32 = undefined;
    _ = try zrx.pipe(&source, .{zrx.collectInto(&buffer)});
}
