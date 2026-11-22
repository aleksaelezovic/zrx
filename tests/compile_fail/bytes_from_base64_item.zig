const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

fn ignore(_: anytype) void {}
fn failed(_: anyerror) void {}

test {
    zrx.program(zrx.range(u32, 0, 3), .{ zrx.map(bytes.fromBase64(std.base64.standard, 4)), zrx.forEach(ignore) }).run(.{zrx.rescue(failed)});
}
