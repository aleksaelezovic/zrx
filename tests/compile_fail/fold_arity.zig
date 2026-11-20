const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;

fn ignore(_: anytype) void {}

// A reducer ends with the state and the item.
fn one(_: u32) u32 {
    return 1;
}
test {
    program(range(u32, 0, 3), .{ zrx.fold(@as(u32, 0), one), forEach(ignore) }).run(.{});
}
