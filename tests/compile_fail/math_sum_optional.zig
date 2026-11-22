const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// Only `min` and `max` have nothing to say before the first item.
test {
    program(range(u32, 0, 3), .{ fold(@as(?u32, null), math.sum), zrx.drain() }).run(.{});
}
