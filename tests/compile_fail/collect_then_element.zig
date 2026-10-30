const zrx = @import("zrx");
fn effect(_: []const bool) void {}
test {
    const source = [_]u32{1};
    _ = zrx.pipe(&source, .{zrx.collectThen(effect)});
}
