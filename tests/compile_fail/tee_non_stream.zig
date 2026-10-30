const zrx = @import("zrx");
test {
    var input = [_]u32{1};
    _ = try zrx.tee(&input);
}
