const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// The items are unsigned: `-1` is none of them. `sub(1)` is what was meant.
test {
    program(range(u32, 0, 3), .{ map(math.add(-1)), zrx.drain() }).run(.{});
}
