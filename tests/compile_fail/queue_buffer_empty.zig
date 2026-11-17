const zrx = @import("zrx");

test {
    var slots: [0]u32 = undefined;
    _ = zrx.queue(&slots);
}
