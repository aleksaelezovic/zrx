//! Archived composition-kernel regression, not a public API example.
const zrx = @import("zrx");
const tryPipe = zrx.tryPipe;
const map = zrx.map;

fn positive(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn double(value: u32) u32 {
    return value * 2;
}

pub fn main() !void {
    const result = try tryPipe(3, .{
        map(.{ positive, double }),
    });
    if (result != 6) return error.UnexpectedResult;

    const failed = tryPipe(0, .{ map(positive), map(double) });
    if (failed) |_| return error.ExpectedFailure else |err| {
        if (err != error.Zero) return err;
    }
}
