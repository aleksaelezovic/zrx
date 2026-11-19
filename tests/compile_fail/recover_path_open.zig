const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const recover = zrx.recover;

fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn ignore(_: anytype) void {}

fn itemOf(failed: zrx.Failed(anyerror, u32)) u32 {
    return failed.item;
}
// A failed item has left the pipe: its path cannot hand anything back.
test {
    try program(range(u32, 0, 3), .{ recover(anyerror, .{map(itemOf)}), map(evenOnly), forEach(ignore) }).run(.{});
}
