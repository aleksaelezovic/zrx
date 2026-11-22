const std = @import("std");
const zrx = @import("zrx");
const text = zrx.ext.text;

fn count(sum: usize, _: []const u8) usize {
    return sum + 1;
}
fn ignore(_: anytype) void {}

// A delimiter is a string, also when it is one byte.
test {
    const texts = [_][]const u8{"a,b"};
    zrx.program(zrx.fromSlice(&texts), .{ zrx.each(text.split(','), .{zrx.fold(@as(usize, 0), count)}), zrx.forEach(ignore) }).run(.{});
}
