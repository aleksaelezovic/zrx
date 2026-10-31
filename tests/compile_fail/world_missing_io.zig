const std = @import("std");
const zrx = @import("zrx");
fn ignore(_: u32) void {}
test "Io is a world bootstrap requirement" {
    const flow = zrx.pipe(zrx.fromValue(@as(u32, 1)), .{zrx.forEach(ignore)});
    try zrx.run(.{std.testing.allocator}, .{flow});
}
