const zrx = @import("zrx");

test {
    _ = zrx.ext.time.throttle(.fromSeconds(-1));
}
