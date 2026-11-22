const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `add(1)` changes one item; what adds up a stream is `sum`.
test {
    program(range(u32, 0, 3), .{ fold(0, math.add(1)), zrx.drain() }).run(.{});
}
