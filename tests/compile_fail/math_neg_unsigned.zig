const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// An unsigned item has no negative.
test {
    program(range(u32, 0, 3), .{ map(math.neg), zrx.drain() }).run(.{});
}
