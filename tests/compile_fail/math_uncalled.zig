const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `add` makes a handler of its operand; it is not one.
test {
    program(range(u32, 0, 3), .{ map(math.add), zrx.drain() }).run(.{});
}
