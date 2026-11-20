const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;

fn ignore(_: anytype) void {}

// A rescue is given the failure: its handler ends with a parameter for it.
fn nothing() void {}
test {
    program(range(u32, 0, 3), .{forEach(ignore)}).run(.{zrx.rescue(nothing)});
}
