const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// The bounds are the wrong way round.
test {
    program(range(u32, 0, 3), .{ map(math.clamp(9, 3)), zrx.drain() }).run(.{});
}
