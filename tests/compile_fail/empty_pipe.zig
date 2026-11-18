const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;

fn double(value: u32) u32 {
    return value * 2;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn ignore(_: u32) void {}

test {
    try program(range(u32, 0, 3), pipe(.{})).run(.{});
}
