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

// A failure taken beyond a queue is handled on another task.
test {
    program(range(u32, 0, 3), .{ recover(anyerror, .{ zrx.queue(2), forEach(ignore) }), map(evenOnly), forEach(ignore) }).run(.{std.testing.io});
}
