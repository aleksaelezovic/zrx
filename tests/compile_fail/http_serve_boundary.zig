const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

test {
    var reader: std.Io.Reader = .fixed("");
    var writer: std.Io.Writer = .fixed(&.{});
    const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
    try zrx.program(zrx.fromValue(connection), .{
        http.serve(.{
            zrx.queue(2),
            http.status(.ok),
        }),
    }).run(.{std.testing.io});
}
