const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn ignore(_: anytype) void {}

// Numbers are not text.
test {
    zrx.program(zrx.range(u32, 0, 3), .{ zrx.map(text.trim(" ")), zrx.forEach(ignore) }).run(.{});
}
