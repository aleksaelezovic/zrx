const std = @import("std");
const world = @import("zrx");
const Database = struct {};
fn effect(_: Database, _: u32) void {}
test "missing dependency" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{ std.testing.allocator, std.testing.io }, .{flow});
}
