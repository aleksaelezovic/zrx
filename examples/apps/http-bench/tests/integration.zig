const std = @import("std");
const protocol = @import("protocol");
const app = @import("app");
const plain = @import("plain");
const options = @import("options");
const io = std.testing.io;
const alloc = std.testing.allocator;

const get = "GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\n\r\n";
const post = "POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n20";
const chunked = "POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n2\r\n1\r\n0\r\n0\r\n\r\n";
const json = "GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
const fixture = get ++ post ++ chunked ++ json ++ get;

const header = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n";
const expected = header ++ "55" ++ header ++ "75" ++ header ++ "75" ++
    "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 27\r\ncontent-type: application/json\r\n\r\n{\"message\":\"Hello, World!\"}";

test "both serve a keep-alive exchange including fixed and chunked POST" {
    inline for (.{ app, plain }) |variant| {
        var input: std.Io.Reader = .fixed(fixture);
        var buffer: [2048]u8 = undefined;
        var output: std.Io.Writer = .fixed(&buffer);
        var server = protocol.Server.init(&input, &output);
        try variant.serve(&server);
        try std.testing.expectEqualStrings(expected, output.buffered());
    }
}

test "both stop on an oversized chunked body" {
    const request = "POST /baseline11 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n21\r\n" ++
        "012345678901234567890123456789012\r\n0\r\n\r\n" ++ get;
    inline for (.{ app, plain }) |variant| {
        var input: std.Io.Reader = .fixed(request);
        var buffer: [1024]u8 = undefined;
        var output: std.Io.Writer = .fixed(&buffer);
        var server = protocol.Server.init(&input, &output);
        try variant.serve(&server);
        try std.testing.expectEqualStrings(
            "HTTP/1.1 413 Payload Too Large\r\nconnection: close\r\ncontent-length: 14\r\ncontent-type: text/plain\r\n\r\nbody too large",
            output.buffered(),
        );
    }
}

test "both executables produce the exact exchange without a network listener" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "request.http", .data = fixture });
    for ([_][]const u8{ options.executable, options.plain_executable }) |exe| {
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, exe, alloc);
        defer alloc.free(path);
        const result = try std.process.run(alloc, io, .{
            .argv = &.{ path, "replay", "request.http" },
            .cwd = .{ .dir = temp.dir },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqualStrings(expected, result.stdout);
    }
}
