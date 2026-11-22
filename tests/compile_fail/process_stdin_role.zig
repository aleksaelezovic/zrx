const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const tap = zrx.tap;
const forEach = zrx.forEach;
const drain = zrx.drain;
const print = zrx.print;
const lines = zrx.lines;
const rescue = zrx.rescue;
const process = zrx.ext.process;

fn small(value: u32) error{TooBig}!u32 {
    if (value > 2) return error.TooBig;
    return value;
}

test {
    var exit: process.Exit = .{};
    _ = &exit;
    program(lines(process.Stdin, 64), .{print(process.Stdout, "{f}\n")}).run(.{ std.testing.io, process.stdin(process.Stdout, 65), process.stdout(process.Stdout, 64) });
}
