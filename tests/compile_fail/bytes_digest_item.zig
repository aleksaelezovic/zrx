const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

const Crc32 = bytes.digest(std.hash.Crc32.init());

fn ignore(_: u32) void {}

test {
    const lines = [_]zrx.Line(16){};
    zrx.program(zrx.fromSlice(&lines), .{ zrx.fold(Crc32{}, Crc32.update), zrx.map(Crc32.final), zrx.forEach(ignore) }).run(.{});
}
