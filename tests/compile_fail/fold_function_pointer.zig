const zrx = @import("zrx");
const fold = zrx.fold;

fn invalid(state: u32, _: u32) u32 {
    return state;
}

test {
    const pointer: *const fn (u32, u32) u32 = &invalid;
    _ = fold(0, pointer);
}
