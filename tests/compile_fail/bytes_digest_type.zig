const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

const Sha256 = bytes.digest(std.crypto.hash.sha2.Sha256);

fn ignore(_: [32]u8) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(Sha256{}, Sha256.update), zrx.map(Sha256.final), zrx.forEach(ignore) }).run(.{});
}
