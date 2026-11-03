const std = @import("std");
const zrx = @import("zrx");
fn config(_: *zrx.Reader) zrx.Reader.Config {
    return .stdin;
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io, zrx.reader(config) }, .{
        zrx.pipe(zrx.fromService(*zrx.Reader), .{zrx.discard()}),
    });
}
