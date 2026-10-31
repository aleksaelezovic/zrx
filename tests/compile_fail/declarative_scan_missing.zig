const std = @import("std");
const zrx = @import("zrx");
const Scale = struct { factor: u32 };
fn add(scale: Scale, state: u64, item: u32) u64 {
    return state + item * scale.factor;
}
fn discard(_: u64) void {}
test "scan reducer requirements must be bound" {
    const flow = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{
        zrx.scan(@as(u64, 0), add),
        zrx.forEach(discard),
    });
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{flow});
}
