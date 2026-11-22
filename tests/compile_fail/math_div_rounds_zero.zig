const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// Not 0 where it is written, and 0 for the items: an `f16` has nothing that small.
test {
    program(zrx.fromSlice(&[_]f16{1}), .{ map(math.div(1e-10)), zrx.drain() }).run(.{});
}
