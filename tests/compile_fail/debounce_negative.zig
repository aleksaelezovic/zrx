const zrx = @import("zrx");

test {
    _ = zrx.debounce(.fromSeconds(-1));
}
