const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fold = zrx.fold;
const math = zrx.ext.math;

// `Stats` takes integers of at most 128 bits.
test {
    const Wide = math.Stats(u256);
    const items = [_]u256{ 1, 2 };
    program(fromSlice(&items), .{ fold(Wide{}, Wide.add), zrx.drain() }).run(.{});
}
