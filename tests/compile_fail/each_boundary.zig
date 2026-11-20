const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const forEach = zrx.forEach;
const each = zrx.each;
const attempt = zrx.attempt;

fn below(n: u32) @TypeOf(range(u32, 0, 0)) {
    return range(u32, 0, n);
}
fn add(sum: u32, value: u32) u32 {
    return sum + value;
}
fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn zero(_: zrx.Failed(error{Odd}, u32)) u32 {
    return 0;
}
fn ignore(_: anytype) void {}

// The sub-pipe lives for one item: a task cannot outlive that.
test {
    try program(range(u32, 0, 3), .{ each(below, .{ zrx.queue(2), fold(@as(u32, 0), add) }), forEach(ignore) }).run(.{std.testing.io});
}
