const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// CityHash hashes one text and is not fed in pieces.
const City = bytes.digest(std.hash.CityHash64{});

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(City{}, City.update), zrx.map(City.final), zrx.forEach(ignore) }).run(.{});
}
