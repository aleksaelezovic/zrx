const zrx = @import("zrx");

test {
    // The first length that is too long: the limit is 2^63 - 1 ns.
    _ = zrx.ext.time.ticks(.{ .nanoseconds = 1 << 63 });
}
