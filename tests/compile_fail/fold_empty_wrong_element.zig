const zrx = @import("zrx");
const pipe = zrx.pipe;
const fold = zrx.fold;

fn accumulate(state: u32, _: bool) u32 {
    return state;
}

test {
    const empty = [_]u32{};
    _ = pipe(&empty, .{fold(0, accumulate)});
}
