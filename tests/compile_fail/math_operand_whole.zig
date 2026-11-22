const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// An `f16` holds no whole number above 65504, whatever type the operand has.
test {
    program(zrx.fromSlice(&[_]f16{1}), .{ map(math.mul(@as(u32, 100000))), zrx.drain() }).run(.{});
}
