const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `std.math.mod` refuses a divisor that is not positive, and so does this.
test {
    program(range(u32, 0, 3), .{ map(math.mod(0)), zrx.drain() }).run(.{});
}
