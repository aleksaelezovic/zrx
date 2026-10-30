const std = @import("std");
const zrx = @import("zrx");
test {
    var input: u32 = 0;
    _ = zrx.readFrom(std.testing.io, &input);
}
