const zrx = @import("zrx");

test {
    _ = zrx.batchWithin(0, .fromSeconds(1));
}
