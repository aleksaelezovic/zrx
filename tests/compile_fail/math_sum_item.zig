const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

// Text cannot be added up.
test {
    const words = [_][]const u8{"a"};
    program(zrx.fromSlice(&words), .{ fold(0, math.sum), zrx.drain() }).run(.{});
}
