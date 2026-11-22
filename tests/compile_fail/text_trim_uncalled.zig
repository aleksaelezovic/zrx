const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn ignore(_: anytype) void {}

// The bytes to strip are always named.
test {
    const texts = [_][]const u8{" a "};
    zrx.program(zrx.fromSlice(&texts), .{ zrx.map(text.trim), zrx.forEach(ignore) }).run(.{});
}
