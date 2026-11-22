const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `sum` is a reducer; the sum of each batch is `map(reduce(0, sum))`.
test {
    program(range(u32, 0, 3), .{ zrx.batch(2), map(math.sum), zrx.drain() }).run(.{});
}
