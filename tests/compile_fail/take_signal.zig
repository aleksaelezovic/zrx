const zrx = @import("zrx");
test {
    const input = [_]u32{1};
    const signal = zrx.pipe(&input, .{zrx.hold(@as(u32, 0))});
    _ = zrx.pipe(&signal, .{zrx.take(1)});
}
