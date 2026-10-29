const zrx = @import("zrx");
const tryFold = zrx.tryFold;

fn invalid(state: u32, _: u32) u32 {
    return state;
}

test {
    _ = tryFold(0, invalid);
}
