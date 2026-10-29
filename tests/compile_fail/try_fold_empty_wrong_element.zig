const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryFold = zrx.tryFold;

fn accumulate(state: u32, _: bool) error{Failed}!u32 {
    return state;
}

test {
    const empty = [_]u32{};
    _ = pipe(&empty, .{tryFold(0, accumulate)});
}
