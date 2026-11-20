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

// What `recover` took before it took a path: a handler.
fn onError(_: anyerror, _: u32) void {}
test {
    program(range(u32, 0, 3), .{ recover(onError, .{forEach(ignore)}), map(evenOnly), forEach(ignore) }).run(.{});
}
