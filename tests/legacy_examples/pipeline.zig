//! Whole-value composition: grouped map transforms run left to right.
//! The first callback's typed argument coerces the literal; the result is 7.
//! Archived composition-kernel regression, not a public API example.
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u32 {
    return value + 1;
}

pub fn main() !void {
    const result: u32 = pipe(3, .{
        map(.{ double, increment }),
    });
    if (result != 7) return error.UnexpectedResult;
}
