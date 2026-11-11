//! The smallest complete program: one source, one pipe, dependencies by type.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const stdout = zrx.stdout;
const print = zrx.print;

const Scale = struct { by: u32 };

fn scale(factor: Scale, value: u32) u32 {
    return value * factor.by;
}
fn isLarge(value: u32) bool {
    return value >= 6;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}

pub fn main(init: std.process.Init) !void {
    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(isLarge),
        fold(0, add),
        stdout(64),
        print(zrx.Stdout, "total: {d}\n"),
    });
    try program(fromSlice(&values), total).run(.{ init.io, Scale{ .by = 2 } });
}
