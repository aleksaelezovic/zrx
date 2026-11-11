const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const subscribe = zrx.subscribe;

fn double(value: u32) u32 {
    return value * 2;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn ignore(_: u32) void {}

const Scale = struct { by: u32 };
test {
    try program(range(u32, 0, 3), pipe(.{subscribe(ignore)})).run(.{ Scale{ .by = 1 }, Scale{ .by = 2 } });
}
