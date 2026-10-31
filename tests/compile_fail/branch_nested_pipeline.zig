const zrx = @import("zrx");
test {
    const input = [_]u8{1};
    _ = zrx.pipe(zrx.fromSlice(&input), .{zrx.branch(.{zrx.otherwise(.{.{zrx.take(1)}})})});
}
