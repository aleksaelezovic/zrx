const zrx = @import("zrx");
fn effect(_: []const u32) void {}
test {
    _ = zrx.collectThen(@as(*const fn ([]const u32) void, &effect));
}
