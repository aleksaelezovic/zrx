const std = @import("std");
const world = @import("zrx");
const Service = struct {};
fn effect(_: *const Service, _: u32) void {}
test "dependency keys are exact not a coercion search" {
    var service: Service = .{};
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{ std.testing.allocator, std.testing.io, &service }, .{flow});
}
