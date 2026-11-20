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
fn ignore(_: u32) void {}
fn zero(_: anyerror, _: u32) u32 {
    return 0;
}
test {
    program(range(u32, 0, 3), pipe(.{ map(zrx.orElse(double, zero)), forEach(ignore) })).run(.{});
}
