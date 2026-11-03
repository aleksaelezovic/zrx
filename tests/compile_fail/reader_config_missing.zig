const std = @import("std");
const zrx = @import("zrx");
const Settings = struct { path: []const u8 };
fn config(settings: Settings) zrx.Reader.Config {
    return .{ .file = settings.path };
}
test {
    try zrx.run(.{ std.testing.allocator, std.testing.io, zrx.reader(config) }, .{
        zrx.pipe(zrx.fromService(*zrx.Reader), .{zrx.discard()}),
    });
}
