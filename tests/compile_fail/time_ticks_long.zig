const zrx = @import("zrx");

test {
    _ = zrx.ext.time.ticks(.fromSeconds(10_000_000_000));
}
