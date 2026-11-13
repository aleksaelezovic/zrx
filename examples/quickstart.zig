//! The smallest complete program: one source, one pipe, dependencies by type.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const subscribe = zrx.subscribe;

const Scale = struct { by: u32 };
const Out = struct { writer: *std.Io.Writer };

fn scale(factor: Scale, value: u32) u32 {
    return value * factor.by;
}
fn isLarge(value: u32) bool {
    return value >= 6;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}
fn report(out: Out, total: u64) !void {
    try out.writer.print("total: {d}\n", .{total});
}

pub fn main(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);

    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(isLarge),
        fold(0, add),
        subscribe(report),
    });
    try program(fromSlice(&values), total).run(.{ Scale{ .by = 2 }, Out{ .writer = &stdout.interface } });
    try stdout.interface.flush();
}
