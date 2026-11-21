const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

fn ignore(_: u32) void {}

test {
    zrx.program(zrx.range(u32, 0, 3), .{ zrx.filter(pattern.digit), zrx.forEach(ignore) }).run(.{});
}
