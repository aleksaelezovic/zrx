const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

// `fail` answers a failure: it ends the error path of a recover, not the pipe.
test {
    var reader: std.Io.Reader = .fixed("");
    var writer: std.Io.Writer = .fixed(&.{});
    const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
    zrx.program(zrx.fromValue(connection), .{http.serve(.{http.fail()})}).run(.{});
}
