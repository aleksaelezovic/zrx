const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

// Nothing says what `0` is: the reducer takes any state.
fn add(sum: anytype, value: u32) @TypeOf(sum) {
    return sum + value;
}

test {
    const rows = [_][2]u32{.{ 1, 2 }};
    program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0, add)), zrx.drain() }).run(.{});
}
