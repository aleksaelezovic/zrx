const zrx = @import("zrx");

test {
    _ = zrx.ext.time.throttle(.fromSeconds(10_000_000_000));
}
