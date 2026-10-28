const zrx = @import("zrx");

fn accept(_: u32) bool {
    return false;
}

fn next(value: u32) u32 {
    return value;
}

test {
    _ = zrx.tryPipe(1, .{ zrx.keepIf(accept), zrx.map(next) });
}
