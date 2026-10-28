const zrx = @import("zrx");
const tryPipe = zrx.tryPipe;
const map = zrx.map;

fn positive(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn double(value: u32) u32 {
    return value *% 2;
}

export fn try_value_coverage(value: u32) u32 {
    return tryPipe(value, .{map(.{ positive, double })}) catch 0;
}

export fn try_input_coverage(value: u32, failed: bool) u32 {
    const initial: error{Initial}!u32 = if (failed) error.Initial else value;
    return tryPipe(initial, .{ map(positive), map(double) }) catch 0;
}
