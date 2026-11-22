const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

fn ignore(_: anytype) void {}

test {
    zrx.program(zrx.range(u32, 0, 3), .{ zrx.map(bytes.base64(std.base64.standard)), zrx.forEach(ignore) }).run(.{});
}
