const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const subscribe = zrx.subscribe;

fn parse(value: u32) error{ Odd, TooBig }!u32 {
    if (value > 100) return error.TooBig;
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn ignore(_: u32) void {}

// The fallback must take every error the handler can fail with.
fn onlyOdd(_: error{Odd}, _: u32) u32 {
    return 0;
}
test {
    try program(range(u32, 0, 3), pipe(.{ map(zrx.orElse(parse, onlyOdd)), subscribe(ignore) })).run(.{});
}
