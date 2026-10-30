const zrx = @import("zrx");
test {
    const input = [_]u32{1};
    _ = zrx.pipe(&input, .{zrx.stdoutLines()});
}
