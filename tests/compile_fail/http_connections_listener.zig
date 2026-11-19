const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    try zrx.program(http.connections(), .{http.serve(.{http.status(.ok)})}).run(.{std.testing.io});
}
