const zrx = @import("zrx");

test {
    const slots = [_]u32{ 0, 0 };
    _ = zrx.queue(&slots);
}
