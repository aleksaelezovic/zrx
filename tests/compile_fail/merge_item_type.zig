const zrx = @import("zrx");
test {
    const a = [_]u32{1};
    const b = [_]u64{2};
    _ = zrx.merge(.{ &a, &b });
}
