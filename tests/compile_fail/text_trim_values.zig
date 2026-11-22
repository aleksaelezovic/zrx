const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn ignore(_: anytype) void {}

// A reducer is given two values, the state and the item.
test {
    const texts = [_][]const u8{" a "};
    zrx.program(zrx.fromSlice(&texts), .{ zrx.fold(@as(usize, 0), text.trimEnd(" ")), zrx.forEach(ignore) }).run(.{});
}
