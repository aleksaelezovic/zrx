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
/// A run that cannot fail: its rescue is never called.
const steady = program(range(u32, 0, 3), .{forEach(ignore)});

// There is nowhere for a value to go. Said where the rescue is written:
// this run cannot fail, so the handler would never be called.
fn status(_: anyerror) u8 {
    return 1;
}
test {
    steady.run(.{rescue(status)});
}
