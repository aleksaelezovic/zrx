const std = @import("std");
const world = @import("zrx");
test "unfinished root" {
    try world.run(.{ std.testing.allocator, std.testing.io }, .{world.fromSlice(&[_]u32{1})});
}
