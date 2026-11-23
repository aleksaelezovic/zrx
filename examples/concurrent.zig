//! Share work between four copies of a pipe, then combine their results.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const rescue = zrx.rescue;
const range = zrx.range;
const concurrent = zrx.concurrent;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const compose = zrx.compose;
const eq = zrx.eq;
const print = zrx.print;
const math = zrx.ext.math;
const pow = math.pow;
const mod = math.mod;
const sum = math.sum;
const process = zrx.ext.process;
const stdout = process.stdout;
const Stdout = process.Stdout;

const isEven = compose(.{ mod(2), eq(0) });

const calculations = pipe(.{
    map(pow(2)),
    filter(isEven),
});

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    const app = program(range(u32, 1, 11), .{
        concurrent(4, calculations),
        fold(@as(u64, 0), sum),
        print(Stdout, "sum of even squares: {d}\n"),
    }).provide(.{stdout(Stdout, 128)});
    // A run returns nothing: what ends it goes to a rescue, and here becomes
    // the exit status.
    app.run(.{ init.io, &exit, rescue(process.fail(.{ .prefix = null })) });
    return exit.code;
}
