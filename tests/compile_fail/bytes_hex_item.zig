const std = @import("std");
const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

const Crc32 = bytes.digest(std.hash.Crc32.init());

test {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{
        zrx.fold(Crc32{}, Crc32.update),
        zrx.map(Crc32.final),
        zrx.map(bytes.hex(.lower)),
        zrx.write(*std.Io.Writer, "{s}\n"),
    }).run(.{ &writer, zrx.rescue(ignore) });
}

fn ignore(_: anyerror) void {}
