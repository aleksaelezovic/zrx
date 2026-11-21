const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// Adler32 has an `update` and no `final`: its checksum is a field.
const Adler32 = bytes.digest(std.hash.Adler32{});

fn ignore(_: u32) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(Adler32{}, Adler32.update), zrx.map(Adler32.final), zrx.forEach(ignore) }).run(.{});
}
