const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

fn ignore(_: u32) void {}

test {
    _ = pattern.set("");
}
