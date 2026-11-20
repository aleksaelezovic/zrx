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

fn double(value: u32) u32 {
    return value * 2;
}
const steady = program(range(u32, 0, 3), .{ map(double), forEach(ignore) });
// Neither program can fail, but two are run as tasks, and that can.
test {
    zrx.system(.{ steady, steady }).run(.{std.testing.io});
}
