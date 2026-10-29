const zrx = @import("zrx");
const fold = zrx.fold;

fn invalid(_: u64, value: u32) u32 {
    return value;
}

test {
    _ = fold(0, invalid);
}
