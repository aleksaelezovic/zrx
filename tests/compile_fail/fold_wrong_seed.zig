const zrx = @import("zrx");
const fold = zrx.fold;

fn accumulate(state: u32, _: u32) u32 {
    return state;
}

test {
    _ = fold(true, accumulate);
}
