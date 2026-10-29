const zrx = @import("zrx");
const tryFold = zrx.tryFold;

fn invalid(_: u64, value: u32) error{Failed}!u32 {
    return value;
}

test {
    _ = tryFold(0, invalid);
}
