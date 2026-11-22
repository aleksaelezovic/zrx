const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// `Stats` is given the type of the items.
test {
    const Words = math.Stats([]const u8);
    program(range(u32, 0, 3), .{ fold(Words{}, Words.add), zrx.drain() }).run(.{});
}
