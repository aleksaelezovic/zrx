const std = @import("std");
const zrx = @import("zrx");

test {
    _ = zrx.concurrent(-1, .{zrx.drain()});
}
