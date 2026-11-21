const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const forEach = zrx.forEach;

/// A predicate that finds a value: the half of an even number.
fn half(value: u32) ?u32 {
    return if (value % 2 == 0) value / 2 else null;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn ignore(_: u32) void {}

test {
    program(range(u32, 0, 3), pipe(.{ zrx.takeWhile(half), forEach(ignore) })).run(.{});
}
