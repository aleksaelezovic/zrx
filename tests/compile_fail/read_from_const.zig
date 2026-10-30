const std = @import("std");
const zrx = @import("zrx");
test {
    var storage: [1]u32 = undefined;
    const input: std.Io.Queue(u32) = .init(&storage);
    _ = zrx.readFrom(std.testing.io, &input);
}
