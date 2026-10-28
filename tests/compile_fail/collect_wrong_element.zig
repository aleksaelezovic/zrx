const zrx = @import("zrx");

test {
    const source = [_]bool{ true, false };
    var output: [2]u32 = undefined;
    _ = zrx.pipe(&source, .{zrx.collectInto(&output)});
}
