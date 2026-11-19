//! Both servers over the same requests: first with the reader and the writer
//! of the connection supplied by the test, then as the two executables, over
//! a loopback socket on a port the system chooses.
const std = @import("std");
const zrx = @import("zrx");
const app = @import("app");
const plain = @import("plain");
const executables = @import("executables");
const http = zrx.ext.http;
const Io = std.Io;
const io = std.testing.io;
const allocator = std.testing.allocator;

const host = "Host: localhost\r\n";
const get = "GET /baseline11?a=13&b=42 HTTP/1.1\r\n" ++ host ++ "\r\n";
const post = "POST /baseline11?a=13&b=42 HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\n\r\n20";
const json = "GET /json HTTP/1.1\r\n" ++ host ++ "\r\n";
const last_json = "GET /json HTTP/1.1\r\n" ++ host ++ "Connection: close\r\n\r\n";

const text_head = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n";
const greeting = "HTTP/1.1 200 OK\r\ncontent-length: 27\r\ncontent-type: application/json\r\n\r\n{\"message\":\"Hello, World!\"}";
const last_greeting = "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 27\r\ncontent-type: application/json\r\n\r\n{\"message\":\"Hello, World!\"}";

fn closed(comptime status: []const u8) []const u8 {
    return "HTTP/1.1 " ++ status ++ "\r\nconnection: close\r\ncontent-length: 0\r\n\r\n";
}

const Zrx = struct {
    fn serve(reader: *Io.Reader, writer: *Io.Writer) !void {
        const connection: http.Transport = .{ .reader = reader, .writer = writer };
        try zrx.program(zrx.fromValue(connection), .{http.serve(app.api)}).run(.{});
    }
};

const Plain = struct {
    fn serve(reader: *Io.Reader, writer: *Io.Writer) !void {
        var server = std.http.Server.init(reader, writer);
        try plain.serve(&server);
    }
};

/// Both servers answer `requests`, sent on one connection, with `answers`.
fn expectBoth(comptime answers: []const u8, comptime requests: []const u8) !void {
    inline for (.{ Zrx, Plain }) |variant| {
        var reader: Io.Reader = .fixed(requests);
        var buffer: [2048]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try variant.serve(&reader, &writer);
        try std.testing.expectEqualStrings(answers, writer.buffered());
    }
}

test "both serve the three workloads on one connection" {
    try expectBoth(text_head ++ "55" ++ text_head ++ "75" ++ greeting ++ text_head ++ "55", get ++ post ++ json ++ get);
}

test "both close the connection when the peer asks" {
    try expectBoth(last_greeting, last_json ++ get);
}

test "both refuse a body they cannot take and close the connection" {
    try expectBoth(closed("413 Payload Too Large"), "POST /baseline11 HTTP/1.1\r\n" ++ host ++ "Content-Length: 33\r\n\r\n" ++ "012345678901234567890123456789012" ++ get);
    try expectBoth(closed("411 Length Required"), "POST /baseline11 HTTP/1.1\r\n" ++ host ++ "\r\n" ++ get);
    try expectBoth(closed("400 Bad Request"), "GET /baseline11 HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\n\r\n20" ++ get);
    try expectBoth(closed("417 Expectation Failed"), "POST /baseline11 HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\nExpect: luck\r\n\r\n20" ++ get);
}

test "both answer a GET of the greeting that carries a body, and close the connection" {
    // Neither looks at the body, and neither can find a request behind it.
    try expectBoth(last_greeting, "GET /json HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\n\r\n20" ++ get);
}

test "neither reads a chunked body" {
    try expectBoth(
        closed("411 Length Required"),
        "POST /baseline11?a=13&b=42 HTTP/1.1\r\n" ++ host ++ "Transfer-Encoding: chunked\r\n\r\n1\r\n2\r\n1\r\n0\r\n0\r\n\r\n" ++ get,
    );
}

// Where no body is involved the plain server still closes the connection
// and zrx keeps it: each is tested by itself.

test "zrx answers an unknown path or method and keeps the connection" {
    var reader: Io.Reader = .fixed("GET /nowhere HTTP/1.1\r\n" ++ host ++ "\r\n" ++ "DELETE /json HTTP/1.1\r\n" ++ host ++ "\r\n" ++
        "PUT /baseline11 HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\n\r\n20" ++ get);
    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try Zrx.serve(&reader, &writer);
    const not_allowed = "HTTP/1.1 405 Method Not Allowed\r\ncontent-length: 0\r\n\r\n";
    try std.testing.expectEqualStrings(
        "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n" ++ not_allowed ++ not_allowed ++ text_head ++ "55",
        writer.buffered(),
    );
}

test "the plain server answers an unknown path or method and closes the connection" {
    inline for (.{
        .{ "GET /nowhere HTTP/1.1\r\n" ++ host ++ "\r\n", "404 Not Found" },
        .{ "DELETE /json HTTP/1.1\r\n" ++ host ++ "\r\n", "405 Method Not Allowed" },
        .{ "PUT /baseline11 HTTP/1.1\r\n" ++ host ++ "Content-Length: 2\r\n\r\n20", "405 Method Not Allowed" },
    }) |case| {
        var reader: Io.Reader = .fixed(case[0] ++ get);
        var buffer: [2048]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        try Plain.serve(&reader, &writer);
        try std.testing.expectEqualStrings(closed(case[1]), writer.buffered());
    }
}

// --- the executables ----------------------------------------------------------

const seconds_allowed = 10;

fn executablePath(exe: []const u8) ![:0]u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, exe, allocator);
}

const Outcome = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

fn run(exe: []const u8, args: []const []const u8) !Outcome {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try executablePath(exe);
    defer allocator.free(path);
    var argv: [4][]const u8 = undefined;
    argv[0] = path;
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(allocator, io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .dir = temp.dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(seconds_allowed), .clock = .awake } },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

test "both executables describe their command line" {
    inline for (.{
        .{ executables.executable, "usage: http-bench serve PORT\n" },
        .{ executables.plain_executable, "usage: http-bench-zig serve PORT\n" },
    }) |case| {
        const help = try run(case[0], &.{"--help"});
        defer allocator.free(help.stdout);
        defer allocator.free(help.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
        try std.testing.expectEqualStrings(case[1], help.stdout);
        try std.testing.expectEqualStrings("", help.stderr);

        const invalid = try run(case[0], &.{ "serve", "http" });
        defer allocator.free(invalid.stdout);
        defer allocator.free(invalid.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, invalid.term);
        try std.testing.expectEqualStrings("", invalid.stdout);
        try std.testing.expectEqualStrings("fatal: InvalidPort\n" ++ case[1], invalid.stderr);
    }
}

/// Reads the port a server announced, sends it `requests` on one connection
/// and reads what it answers until it closes the connection.
fn converse(announced: Io.File, requests: []const u8, answers: []u8, done: *Io.Event) ![]const u8 {
    defer done.set(io);
    var line: [16]u8 = undefined;
    var ports = announced.readerStreaming(io, &line);
    const port = try std.fmt.parseInt(u16, try ports.interface.takeDelimiterExclusive('\n'), 10);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    try out.interface.writeAll(requests);
    var in = stream.reader(io, &.{});
    return answers[0..try in.interface.readSliceShort(answers)];
}

/// Starts `exe serve 0` and holds one conversation with it. The whole of it
/// is bounded, and the server is killed and reaped however it ends.
fn overLoopback(exe: []const u8, requests: []const u8, answers: []u8) ![]const u8 {
    const path = try executablePath(exe);
    defer allocator.free(path);
    var child = try std.process.spawn(io, .{
        .argv = &.{ path, "serve", "0" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var done: Io.Event = .unset;
    var conversation = try io.concurrent(converse, .{ child.stdout.?, requests, answers, &done });
    defer _ = conversation.cancel(io) catch {};
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(seconds_allowed), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    while (!done.isSet()) {
        done.waitTimeout(io, deadline) catch |failure| switch (failure) {
            error.Timeout => {
                // An event may wake for nothing: the deadline decides.
                if (deadline.deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.ServerTimedOut;
            },
            else => return failure,
        };
    }
    return conversation.await(io);
}

test "both executables announce their port and serve the workloads over loopback" {
    inline for (.{ executables.executable, executables.plain_executable }) |exe| {
        var answers: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(
            text_head ++ "55" ++ text_head ++ "75" ++ last_greeting,
            try overLoopback(exe, get ++ post ++ last_json, &answers),
        );
    }
}
