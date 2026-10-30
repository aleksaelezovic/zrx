const std = @import("std");
const zrx = @import("zrx");
test {
    _ = try zrx.share(std.testing.allocator, std.testing.io, 1, [_]u32{ 1, 2 });
}
