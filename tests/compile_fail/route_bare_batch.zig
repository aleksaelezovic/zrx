const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;

// `batch` is built from two stages, but to its user it is one operator: a
// sub-pipe still has to be an operator tuple or `pipe(.{ ... })`.
test {
    program(range(u32, 0, 3), pipe(.{zrx.route(.{zrx.otherwise(zrx.batch(2))})})).run(.{});
}
