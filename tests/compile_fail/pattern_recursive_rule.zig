const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

test {
    _ = pattern.recursive(pattern.lower, .{});
}
