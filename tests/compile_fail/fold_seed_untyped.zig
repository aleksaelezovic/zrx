const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

// Nothing says what `0` is: the reducer takes any state.
fn add(sum: anytype, value: u32) @TypeOf(sum) {
    return sum + value;
}

test {
    program(range(u32, 0, 3), .{ zrx.fold(0, add), zrx.drain() }).run(.{});
}
