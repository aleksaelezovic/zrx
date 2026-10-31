const std = @import("std");
const world = @import("zrx");
fn effect(_: u32) void {}
test "allocator is a world requirement even without user requests" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{std.testing.io}, .{flow});
}
