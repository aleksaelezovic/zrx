const zrx = @import("zrx");

test {
    var slots: [2]u32 align(1) = undefined;
    _ = zrx.queue(&slots);
}
