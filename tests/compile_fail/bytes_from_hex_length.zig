const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

fn ignore(_: anytype) void {}
fn failed(_: anyerror) void {}

test {
    const texts = [_][6]u8{"7a7278".*};
    zrx.program(zrx.fromSlice(&texts), .{ zrx.map(bytes.fromHex(4)), zrx.forEach(ignore) }).run(.{zrx.rescue(failed)});
}
