const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

fn method(request: http.Request) http.Method {
    return request.method();
}

test {
    var reader: std.Io.Reader = .fixed("");
    var writer: std.Io.Writer = .fixed(&.{});
    const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
    zrx.program(zrx.fromValue(connection), .{http.serve(.{zrx.map(method)})}).run(.{});
}
