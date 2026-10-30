const zrx = @import("zrx");
test {
    var input: zrx.Stream(u32) = undefined;
    const prefix = zrx.pipe(&input, .{zrx.take(1)});
    _ = prefix.iterator();
}
