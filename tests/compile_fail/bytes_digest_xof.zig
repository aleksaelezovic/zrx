const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// An XOF of Ascon fills a slice of any length and has no length of its own.
const Xof = bytes.digest(std.crypto.hash.ascon.AsconXof128.init(.{}));

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(Xof{}, Xof.update), zrx.map(Xof.final), zrx.forEach(ignore) }).run(.{});
}
