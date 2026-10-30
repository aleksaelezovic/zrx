const zrx = @import("zrx");
fn effect(_: []const u32) void {}
test {
    _ = zrx.batchThen(2, @as(*const fn ([]const u32) void, &effect));
}
