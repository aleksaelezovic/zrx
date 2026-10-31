const std = @import("std");
const world = @import("zrx");
fn effect(_: anytype, _: u32) void {}
test "dependencies must be a struct" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{ std.testing.allocator, std.testing.io, @as(u8, 0) }, .{flow});
}
