//! The smallest complete program: one source, one pipe, dependencies by type.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const rescue = zrx.rescue;
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

const Exit = struct { code: u8 = 0 };

/// A run returns nothing: what ends it goes to a rescue, and here becomes
/// the exit status.
fn fail(exit: *Exit, _: anyerror) void {
    exit.code = 1;
}

pub fn main(init: std.process.Init) u8 {
    var exit: Exit = .{};
    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(isLarge),
        fold(0, add),
        print(zrx.Stdout, "total: {d}\n"),
    });
    program(fromSlice(&values), total)
        .provide(.{stdout(64)}) // a default; it could as well be given to `run`
        .run(.{
        init.io,
        Scale{ .by = 2 },
        &exit,
        rescue(fail),
    });
    return exit.code;
}
