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
const ge = zrx.ge;
const print = zrx.print;
const sum = zrx.ext.math.sum;
const process = zrx.ext.process;
const stdout = process.stdout;
const Stdout = process.Stdout;

const Scale = struct { by: u32 };

/// A handler names what it needs before its item: `Scale` is given to `run`.
fn scale(factor: Scale, value: u32) u32 {
    return value * factor.by;
}

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(ge(6)),
        fold(@as(u64, 0), sum),
        print(Stdout, "total: {d}\n"),
    });
    program(fromSlice(&values), total)
        .provide(.{stdout(Stdout, 64)}) // a default; it could as well be given to `run`
        .run(.{
        init.io,
        Scale{ .by = 2 },
        &exit,
        // A run returns nothing: what ends it goes to a rescue, and here
        // becomes the exit status.
        rescue(process.fail(.{ .prefix = null })),
    });
    return exit.code;
}
