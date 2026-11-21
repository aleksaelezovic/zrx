const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

fn ignore(_: u32) void {}

test {
    _ = pattern.Extracted(pattern.seq(.{ pattern.extract(.a, pattern.digit), pattern.extract(.a, pattern.digit) }));
}
