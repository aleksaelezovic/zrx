const std = @import("std");
const zrx = @import("zrx");
test {
    var storage: [1]u32 = undefined;
    var input: std.Io.Queue(u32) = .init(&storage);
    _ = try zrx.tee(&input);
}
