const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn ignore(_: anytype) void {}

// A slice points at bytes that are not the handler's to change.
test {
    const texts = [_][]const u8{"a"};
    zrx.program(zrx.fromSlice(&texts), .{ zrx.map(text.toUpper), zrx.forEach(ignore) }).run(.{});
}
