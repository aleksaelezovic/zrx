const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// A float does not overflow: there is nothing to check.
test {
    const values = [_]f64{1};
    program(zrx.fromSlice(&values), .{ map(math.checked.add(1)), zrx.drain() }).run(.{});
}
