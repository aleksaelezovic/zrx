const zrx = @import("zrx");

fn effect(_: u32) error{Failed}!void {}
fn next(value: u32) u32 {
    return value;
}

test {
    _ = zrx.pipe(1, .{ zrx.tap(effect), zrx.map(next) });
}
