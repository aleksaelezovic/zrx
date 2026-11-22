const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// A bound has to be a value of the items' type.
test {
    program(range(u32, 0, 3), .{ map(math.clamp(-5, 5)), zrx.drain() }).run(.{});
}
