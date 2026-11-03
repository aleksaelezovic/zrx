const std = @import("std");
const zrx = @import("zrx");
const Nested = struct { value: u32 };
fn select(_: u32) @TypeOf(zrx.fromService(Nested)) {
    return zrx.fromService(Nested);
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{
        zrx.pipe(zrx.fromValue(@as(u32, 1)), .{ zrx.flatMap(select), zrx.discard() }),
    });
}
