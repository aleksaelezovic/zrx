const zrx = @import("zrx");
const fold = zrx.fold;

fn invalid(state: u32, _: u32) u32 {
    return state;
}

test {
    _ = fold(0, .{invalid});
}
