const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// As for `div`: the operand is judged as the items' type has it.
test {
    program(zrx.fromSlice(&[_]f16{1}), .{ map(math.mod(1e-10)), zrx.drain() }).run(.{});
}
