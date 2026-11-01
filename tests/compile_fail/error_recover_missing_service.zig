const std = @import("std");
const zrx = @import("zrx");
const Replacement = struct { value: u32 };
fn replace(service: Replacement, _: error{Bad}) u32 {
    return service.value;
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{
        zrx.pipe(zrx.fromValue(@as(u32, 1)), .{ zrx.recover(replace), zrx.discard() }),
    });
}
