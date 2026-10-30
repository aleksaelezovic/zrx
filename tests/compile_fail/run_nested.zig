const std = @import("std");
const zrx = @import("zrx");
fn ignore(_: u32) void {}
fn produce(_: *zrx.Emitter(u32)) void {}
test {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const flow = zrx.pipe(&source, .{zrx.forEach(ignore)});
    try zrx.run(std.testing.allocator, std.testing.io, .{.{flow}});
}
