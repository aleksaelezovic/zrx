const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// The checked forms judge an operand as the plain ones do.
test {
    program(zrx.fromSlice(&[_]u8{1}), .{ map(math.checked.mul(256)), zrx.drain() }).run(.{});
}
