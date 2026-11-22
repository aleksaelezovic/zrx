const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// The seed chose a state that is narrower than the items.
test {
    program(range(u32, 0, 3), .{ fold(@as(u8, 0), math.sum), zrx.drain() }).run(.{});
}
