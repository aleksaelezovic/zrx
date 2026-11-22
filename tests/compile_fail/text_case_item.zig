const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn ignore(_: anytype) void {}

test {
    zrx.program(zrx.range(u32, 0, 3), .{ zrx.map(text.toLower), zrx.forEach(ignore) }).run(.{});
}
