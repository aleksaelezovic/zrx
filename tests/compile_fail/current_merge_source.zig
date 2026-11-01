const zrx = @import("zrx");
test {
    const values = [_]u32{ 1, 2 };
    _ = zrx.merge(.{&values});
}
