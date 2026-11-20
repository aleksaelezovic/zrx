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
const print = zrx.print;
const stdout = zrx.stdout;

fn square(value: u32) u32 {
    return value * value;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}

const calculations = pipe(.{
    map(square),
    filter(isEven),
});

const Exit = struct { code: u8 = 0 };

/// A run returns nothing: what ends it goes to a rescue, and here becomes
/// the exit status.
fn fail(exit: *Exit, _: anyerror) void {
    exit.code = 1;
}

pub fn main(init: std.process.Init) u8 {
    var exit: Exit = .{};
    const app = program(range(u32, 1, 11), .{
        concurrent(4, calculations),
        fold(0, add),
        print(zrx.Stdout, "sum of even squares: {d}\n"),
    }).provide(.{stdout(128)});
    app.run(.{ init.io, &exit, rescue(fail) });
    return exit.code;
}
