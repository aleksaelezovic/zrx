const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const rescue = zrx.rescue;

fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn ignore(_: anytype) void {}
const failing = program(range(u32, 0, 3), .{ map(evenOnly), forEach(ignore) });

fn loose(value: u32) anyerror!u32 {
    return value;
}
fn zero(_: anytype) u32 {
    return 0;
}
// The same where the sub-pipe can fail with anything.
test {
    program(range(u32, 0, 3), .{ zrx.attempt(.{map(loose)}, error{Canceled}, .{map(zero)}), forEach(ignore) }).run(.{});
}
