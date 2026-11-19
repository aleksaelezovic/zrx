const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    var reader: std.Io.Reader = .fixed("");
    var writer: std.Io.Writer = .fixed(&.{});
    const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
    try zrx.program(zrx.fromValue(connection), .{http.serve(.{http.status(.early_hints)})}).run(.{});
}
