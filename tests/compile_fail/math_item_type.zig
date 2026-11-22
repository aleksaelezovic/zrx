const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const math = zrx.ext.math;

const Order = struct { cents: u32 };

// The item is a struct that holds the number.
test {
    const orders = [_]Order{.{ .cents = 1 }};
    program(zrx.fromSlice(&orders), .{ map(math.mul(2)), zrx.drain() }).run(.{});
}
