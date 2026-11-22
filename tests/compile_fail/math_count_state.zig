const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// A count is a whole number.
test {
    program(range(u32, 0, 3), .{ fold(@as(f64, 0), math.count), zrx.drain() }).run(.{});
}
