const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// A bound is an operand like any: this one would be no bound for an `f32`.
test {
    program(zrx.fromSlice(&[_]f32{1}), .{ map(math.clamp(0, 1e300)), zrx.drain() }).run(.{});
}
