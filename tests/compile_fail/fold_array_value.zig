const zrx = @import("zrx");
const pipe = zrx.pipe;
const fold = zrx.fold;

fn accumulate(state: u32, value: u32) u32 {
    return state + value;
}

test {
    const source = [_]u32{ 1, 2 };
    _ = pipe(source, .{fold(0, accumulate)});
}
