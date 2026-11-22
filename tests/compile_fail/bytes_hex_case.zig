const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

fn ignore(_: anytype) void {}

test {
    const words = [_][4]u8{"zrx!".*};
    zrx.program(zrx.fromSlice(&words), .{ zrx.map(bytes.hex(.mixed)), zrx.forEach(ignore) }).run(.{});
}
