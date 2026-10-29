const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;
const tryFold = zrx.tryFold;

fn accumulate(state: u32, value: u32) error{Failed}!u32 {
    return state + value;
}

fn plain(value: u32) u32 {
    return value;
}

test {
    const source = [_]u32{1};
    _ = pipe(&source, .{ tryFold(0, accumulate), map(plain) });
}
