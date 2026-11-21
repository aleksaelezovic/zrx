const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

test {
    _ = pattern.oneOf(.{ .maybe = pattern.optional(pattern.digit), .letter = pattern.lower });
}
