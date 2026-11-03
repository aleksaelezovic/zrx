const std = @import("std");
const zrx = @import("zrx");
const Service = struct { delimiter: u8 };
fn delimiter(service: Service, value: u8) bool {
    return value == service.delimiter;
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{zrx.pipe(zrx.fromValue(@as([]const u8, "a")), .{
        zrx.splitBy(delimiter, .{ .max_items = 8 }), zrx.discard(),
    })});
}
