const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

test {
    _ = pattern.as(zrx.Line(8), pattern.extract(.a, pattern.digit));
}
