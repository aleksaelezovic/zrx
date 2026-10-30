const zrx = @import("zrx");
test {
    _ = zrx.pipe([_]u32{ 1, 2 }, .{zrx.takeLast(1)});
}
