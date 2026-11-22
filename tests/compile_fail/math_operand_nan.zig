const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// Every result would be NaN.
test {
    program(zrx.fromSlice(&[_]f64{1}), .{ map(math.add(std.math.nan(f64))), zrx.drain() }).run(.{});
}
