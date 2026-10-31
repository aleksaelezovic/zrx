const std = @import("std");
const world = @import("zrx");
const A = struct {};
const B = struct {};
fn acquireA(_: B, _: u8) A {
    return .{};
}
fn acquireB(_: A, _: u8) B {
    return .{};
}
fn releaseA(_: A) void {}
fn releaseB(_: B) void {}
fn effect(_: A, _: u32) void {}
test "dependency cycle" {
    const flow = world.pipe(world.fromSlice(&[_]u32{1}), .{world.forEach(effect)});
    try world.run(.{
        std.testing.allocator,
        std.testing.io,
        world.resource(@as(u8, 0), acquireA, releaseA),
        world.resource(@as(u8, 0), acquireB, releaseB),
    }, .{flow});
}
