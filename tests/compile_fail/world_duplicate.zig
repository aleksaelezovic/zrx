const std = @import("std");
const world = @import("zrx");
const Service = struct {};
fn acquire(_: u8) Service {
    return .{};
}
fn release(_: Service) void {}
fn effect(_: u32) void {}
test "provided type duplicates borrowed binding" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{
        std.testing.allocator,
        std.testing.io,
        Service{},
        world.resource(@as(u8, 0), acquire, release),
    }, .{flow});
}
