const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;

fn ignore(_: anytype) void {}

fn nothing() void {}
test {
    program(range(u32, 0, 3), .{ zrx.scan(@as(u32, 0), nothing), forEach(ignore) }).run(.{});
}
