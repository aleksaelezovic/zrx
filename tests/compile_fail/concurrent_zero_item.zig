const std = @import("std");
const zrx = @import("zrx");

test {
    zrx.program(zrx.fromValue(@as(void, {})), .{zrx.concurrent(2, .{zrx.drain()})}).run(.{std.testing.io});
}
