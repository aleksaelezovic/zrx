const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const fold = zrx.fold;
const forEach = zrx.forEach;
const each = zrx.each;
const attempt = zrx.attempt;

fn below(n: u32) @TypeOf(range(u32, 0, 0)) {
    return range(u32, 0, n);
}
fn add(sum: u32, value: u32) u32 {
    return sum + value;
}
fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn zero(_: error{Odd}, _: u32) u32 {
    return 0;
}
fn ignore(_: anytype) void {}

fn parse(value: u32) error{ Odd, TooBig }!u32 {
    if (value > 100) return error.TooBig;
    return evenOnly(value);
}

// The fallback must take every error the sub-pipe can fail with.
test {
    try program(range(u32, 0, 3), .{ attempt(.{map(parse)}, zero), forEach(ignore) }).run(.{});
}
