const std = @import("std");
const world = @import("zrx");
fn acquire(_: u8) std.mem.Allocator {
    return std.testing.allocator;
}
fn release(_: std.mem.Allocator) void {}
fn effect(_: u32) void {}
test "bootstrap cannot be a managed recipe" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{ world.resource(@as(u8, 0), acquire, release), std.testing.io }, .{flow});
}
