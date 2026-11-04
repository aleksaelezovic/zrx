const std = @import("std");
const zrx = @import("zrx");
const Service = struct { value: i32 };
fn check(service: Service, value: i32) bool {
    return value == service.value;
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{
        zrx.pipe(zrx.fromValue(@as(i32, 1)), .{ zrx.filter(zrx.any(check)), zrx.discard() }),
    });
}
