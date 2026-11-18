const zrx = @import("zrx");

fn matches(_: u32) bool {
    return true;
}

test {
    _ = zrx.when(matches, zrx.drain());
}
