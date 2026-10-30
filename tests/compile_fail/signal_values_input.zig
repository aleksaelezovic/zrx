const zrx = @import("zrx");
test {
    const updates = [_]u32{1};
    _ = zrx.values(&updates);
}
