const zrx = @import("zrx");
const fold = zrx.fold;

fn invalid(value: u32) u32 {
    return value;
}

test {
    _ = fold(0, invalid);
}
