const std = @import("std");
const zrx = @import("zrx");
test {
    const input = try zrx.Stream(u32).init(std.testing.allocator, std.testing.io, 1);
    _ = try zrx.tee(&input);
}
