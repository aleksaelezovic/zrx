const std = @import("std");
const zrx = @import("zrx");
test {
    try zrx.run(std.testing.allocator, std.testing.io, .{});
}
