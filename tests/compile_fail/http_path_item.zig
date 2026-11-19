const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    try zrx.program(zrx.range(u32, 0, 3), .{
        zrx.filter(http.path("/")),
        zrx.drain(),
    }).run(.{});
}
