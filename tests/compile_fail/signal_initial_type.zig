const zrx = @import("zrx");
test {
    const updates = [_]bool{true};
    _ = zrx.pipe(&updates, .{zrx.hold(1)});
}
