const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const map = zrx.map;
const math = zrx.ext.math;

// Larger than every `f32`: rounded, it would add infinity to each item.
test {
    program(zrx.fromSlice(&[_]f32{1}), .{ map(math.add(1e300)), zrx.drain() }).run(.{});
}
