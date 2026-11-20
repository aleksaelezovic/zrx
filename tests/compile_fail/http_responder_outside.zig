const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    zrx.program(zrx.range(u32, 0, 3), .{http.text("{d}")}).run(.{});
}
