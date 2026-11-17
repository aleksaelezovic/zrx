const zrx = @import("zrx");

test {
    _ = zrx.batchWithin(3, .fromSeconds(-1));
}
