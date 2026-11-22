const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `pow` multiplies a whole number of times.
test {
    program(range(u32, 0, 3), .{ map(math.pow(0.5)), zrx.drain() }).run(.{});
}
