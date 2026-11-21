const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;

fn length(path: []const u8) usize {
    return path.len;
}

test {
    const api = zrx.pipe(.{zrx.route(.{zrx.when(http.path(length), .{http.status(.ok)})})});
    var reader: std.Io.Reader = .fixed("");
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
    zrx.program(zrx.fromValue(connection), .{http.serve(api)}).run(.{zrx.rescue(ignore)});
}

fn ignore(_: anyerror) void {}
