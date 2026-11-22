const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// Murmur hashes one text and is not fed in pieces.
const Murmur = bytes.digest(std.hash.Murmur2_32{});

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(Murmur{}, Murmur.update), zrx.map(Murmur.final), zrx.forEach(ignore) }).run(.{});
}
