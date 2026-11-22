const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// Known where it is written: nothing is divided by 0.
test {
    program(range(u32, 0, 3), .{ map(math.div(0)), zrx.drain() }).run(.{});
}
