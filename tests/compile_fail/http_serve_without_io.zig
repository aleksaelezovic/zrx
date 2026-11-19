const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    const waiting = [_]http.Connection{};
    try zrx.program(zrx.fromSlice(&waiting), .{http.serve(.{http.status(.ok)})}).run(.{});
}
