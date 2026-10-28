const zrx = @import("zrx");

test {
    const storage = [_]u32{ 1, 2 };
    _ = zrx.collectInto(&storage);
}
