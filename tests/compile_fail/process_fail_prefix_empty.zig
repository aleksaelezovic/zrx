const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const drain = zrx.drain;
const rescue = zrx.rescue;
const process = zrx.ext.process;

fn small(value: u32) error{TooBig}!u32 {
    if (value > 2) return error.TooBig;
    return value;
}

test {
    var exit: process.Exit = .{};
    program(range(u32, 0, 4), .{ map(small), drain() }).run(.{ &exit, rescue(process.fail(.{ .prefix = "" })) });
}
