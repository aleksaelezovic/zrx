//! `zrx.ext.http`: serving HTTP/1.1.
//!
//! Most tests hand `serve` a connection made of a reader and a writer of
//! their own, so what the peer sends, when it arrives and what was written
//! are all chosen and observed by the test. Two use a loopback socket.
const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;
const Io = std.Io;
const io = std.testing.io;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const tap = zrx.tap;
const fold = zrx.fold;
const branch = zrx.branch;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const recover = zrx.recover;
const concurrent = zrx.concurrent;
const forEach = zrx.forEach;
const resource = zrx.resource;
const all = zrx.all;
const constant = zrx.constant;

// ---------------------------------------------------------------------------
// The pipe under test
// ---------------------------------------------------------------------------

/// The sum of the query's values and the number in the body.
fn sum(request: http.Request) !i64 {
    var total: i64 = 0;
    var pairs = request.query();
    while (pairs.next()) |pair| total += std.fmt.parseInt(i64, pair.value, 10) catch 0;
    var buffer: [8]u8 = undefined;
    const body = try request.body(&buffer);
    return total + (std.fmt.parseInt(i64, body, 10) catch 0);
}

const Greeting = struct { message: []const u8 };
const hello: Greeting = .{ .message = "Hello, World!" };

fn agent(request: http.Request) struct { []const u8, http.Method } {
    return .{ request.header("user-agent") orelse "nobody", request.method() };
}

/// Fails with the error its path names.
fn refuse(request: http.Request) !u8 {
    const failures = .{
        .{ "/bad", error.BadRequest },
        .{ "/missing", error.NotFound },
        .{ "/method", error.MethodNotAllowed },
        .{ "/length", error.LengthRequired },
        .{ "/large", error.PayloadTooLarge },
        .{ "/expect", error.ExpectationFailed },
        .{ "/other", error.OutOfLuck },
    };
    inline for (failures) |failure| if (std.mem.eql(u8, request.path(), failure[0])) return failure[1];
    return 0;
}

fn teapot(response: http.Response, _: http.Request) !void {
    try response.send(.teapot, "text/plain", "short and stout");
}

const routes = route(.{
    when(http.path("/sum"), .{
        map(sum),
        http.text("{d}"),
    }),
    when(all(.{ http.path("/json"), http.method(.GET) }), .{
        map(constant(hello)),
        http.json(),
    }),
    when(http.path("/json"), .{http.status(.method_not_allowed)}),
    when(http.path("/agent"), .{
        map(agent),
        http.text("{s} sent {t}"),
    }),
    when(http.path("/teapot"), .{forEach(teapot)}),
    when(http.path("/dropped"), .{
        filter(constant(false)),
        http.status(.ok),
    }),
    when(http.path("/twice"), .{branch(.{
        .{http.status(.accepted)},
        .{http.status(.ok)},
    })}),
    otherwise(.{
        map(refuse),
        http.text("{d}"),
    }),
});

const api = pipe(.{
    recover(http.fail),
    routes,
});

// ---------------------------------------------------------------------------
// A peer the test controls
// ---------------------------------------------------------------------------

/// What the server wrote, and in how many writes.
const Wire = struct {
    writer: Io.Writer,
    buffer: [512]u8 = undefined,
    sent: [4096]u8 = undefined,
    len: usize = 0,
    writes: usize = 0,

    fn init(wire: *Wire) void {
        wire.* = .{ .writer = .{ .buffer = &wire.buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const wire: *Wire = @alignCast(@fieldParentPtr("writer", writer));
        wire.writes += 1;
        _ = wire.append(writer.buffered());
        writer.end = 0;
        var taken: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| taken += wire.append(bytes);
        for (0..splat) |_| taken += wire.append(data[data.len - 1]);
        return taken;
    }

    fn append(wire: *Wire, bytes: []const u8) usize {
        @memcpy(wire.sent[wire.len..][0..bytes.len], bytes);
        wire.len += bytes.len;
        return bytes.len;
    }

    fn text(wire: *const Wire) []const u8 {
        return wire.sent[0..wire.len];
    }
};

/// Serves `arrivals`, each of which reaches the server in a read of its own.
fn converse(sub: anytype, arrivals: []const std.testing.Reader.Call, wire: *Wire) !void {
    var head: [512]u8 = undefined;
    var peer: std.testing.Reader = .init(&head, arrivals);
    wire.init();
    const connection: http.Transport = .{ .reader = &peer.interface, .writer = &wire.writer };
    try program(fromValue(connection), .{http.serve(sub)}).run(.{});
}

/// What `api` answers to `request`, sent alone.
fn expectAnswer(comptime answer: []const u8, comptime request: []const u8) !void {
    var wire: Wire = undefined;
    try converse(api, &.{.{ .buffer = request }}, &wire);
    try std.testing.expectEqualStrings(answer, wire.text());
}

inline fn ok(comptime content_type: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\ncontent-type: {s}\r\n\r\n{s}", .{ body.len, content_type, body });
}

/// An empty answer after which the connection goes on, or is closed.
inline fn empty(comptime code: []const u8, comptime then: enum { open, closed }) []const u8 {
    return "HTTP/1.1 " ++ code ++ "\r\n" ++ (if (then == .closed) "connection: close\r\n" else "") ++ "content-length: 0\r\n\r\n";
}

inline fn times(comptime n: usize, comptime text: []const u8) []const u8 {
    return comptime repeated: {
        var out: []const u8 = "";
        for (0..n) |_| out = out ++ text;
        break :repeated out;
    };
}

const get_sum = "GET /sum?a=13&b=42 HTTP/1.1\r\nHost: test\r\n\r\n";
const post_sum = "POST /sum?a=13&b=42 HTTP/1.1\r\nHost: test\r\nContent-Length: 2\r\n\r\n20";
const get_json = "GET /json HTTP/1.1\r\nHost: test\r\n\r\n";

// ---------------------------------------------------------------------------
// Responders
// ---------------------------------------------------------------------------

test "text formats the item as the body" {
    try expectAnswer(ok("text/plain", "55"), get_sum);
}

test "text takes a tuple item as several format arguments" {
    try expectAnswer(ok("text/plain", "zig sent GET"), "GET /agent HTTP/1.1\r\nUser-Agent: zig\r\n\r\n");
    try expectAnswer(ok("text/plain", "nobody sent POST"), "POST /agent HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
}

test "json writes the item with std.json" {
    try expectAnswer(ok("application/json", "{\"message\":\"Hello, World!\"}"), get_json);
}

test "status answers a code and no body" {
    try expectAnswer(empty("405 Method Not Allowed", .open), "DELETE /json HTTP/1.1\r\n\r\n");
}

test "a status without a body carries no length, and the connection goes on" {
    const no_content = "HTTP/1.1 204 No Content\r\n\r\n";
    const nothing = pipe(.{http.status(.no_content)});
    var wire: Wire = undefined;
    // A body nobody read is skipped, as it is before any other answer.
    try converse(nothing, &.{.{ .buffer = get_sum ++ post_sum ++ get_sum }}, &wire);
    try std.testing.expectEqualStrings(times(3, no_content), wire.text());
    try converse(nothing, &.{.{ .buffer = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n" ++ get_sum }}, &wire);
    try std.testing.expectEqualStrings("HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n", wire.text());
    try converse(nothing, &.{.{ .buffer = "HEAD / HTTP/1.1\r\n\r\n" }}, &wire);
    try std.testing.expectEqualStrings(no_content, wire.text());
}

test "a handler answers through the Response dependency" {
    try expectAnswer(
        "HTTP/1.1 418 I'm a teapot\r\ncontent-length: 15\r\ncontent-type: text/plain\r\n\r\nshort and stout",
        "GET /teapot HTTP/1.1\r\n\r\n",
    );
}

test "a HEAD request is answered with the head alone" {
    try expectAnswer("HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n", "HEAD /sum?a=13&b=42 HTTP/1.1\r\n\r\n");
}

test "a request the pipe did not answer is answered 500" {
    try expectAnswer(empty("500 Internal Server Error", .open), "GET /dropped HTTP/1.1\r\n\r\n");
}

test "a second answer writes nothing and closes the connection" {
    var wire: Wire = undefined;
    try converse(api, &.{.{ .buffer = "GET /twice HTTP/1.1\r\n\r\n" ++ get_sum }}, &wire);
    try std.testing.expectEqualStrings(empty("202 Accepted", .open), wire.text());
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

test "the body is read whether its length is given or it is chunked" {
    try expectAnswer(ok("text/plain", "75"), post_sum);
    try expectAnswer(ok("text/plain", "75"), "POST /sum?a=13&b=42 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n2\r\n1\r\n0\r\n0\r\n\r\n");
}

test "a body is awaited from a peer that expects to be told to continue" {
    var wire: Wire = undefined;
    try converse(api, &.{
        .{ .buffer = "POST /sum HTTP/1.1\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\n" },
        .{ .buffer = "20" },
    }, &wire);
    try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n" ++ ok("text/plain", "20"), wire.text());
}

test "a query pair without a value has an empty one, and nothing is decoded" {
    try expectAnswer(ok("text/plain", "7"), "GET /sum?flag&&a=7&b=&c=%37 HTTP/1.1\r\n\r\n");
}

// ---------------------------------------------------------------------------
// Keep-alive, pipelining and flushing
// ---------------------------------------------------------------------------

test "requests on one connection are answered in order until the peer closes it" {
    var wire: Wire = undefined;
    try converse(api, &.{ .{ .buffer = get_sum }, .{ .buffer = post_sum }, .{ .buffer = get_json } }, &wire);
    try std.testing.expectEqualStrings(
        ok("text/plain", "55") ++ ok("text/plain", "75") ++ ok("application/json", "{\"message\":\"Hello, World!\"}"),
        wire.text(),
    );
}

test "requests that arrive one at a time are each answered with a write" {
    var wire: Wire = undefined;
    try converse(api, &.{ .{ .buffer = get_sum }, .{ .buffer = post_sum }, .{ .buffer = get_json } }, &wire);
    try std.testing.expectEqual(3, wire.writes);
}

test "pipelined requests are answered with one write" {
    var wire: Wire = undefined;
    try converse(api, &.{.{ .buffer = get_sum ++ post_sum ++ get_json ++ get_sum }}, &wire);
    try std.testing.expectEqual(1, wire.writes);
    try std.testing.expectEqualStrings(
        ok("text/plain", "55") ++ ok("text/plain", "75") ++ ok("application/json", "{\"message\":\"Hello, World!\"}") ++ ok("text/plain", "55"),
        wire.text(),
    );
}

test "a write covers the requests that had arrived together" {
    var wire: Wire = undefined;
    try converse(api, &.{ .{ .buffer = get_sum ++ get_json }, .{ .buffer = post_sum ++ get_sum ++ get_sum } }, &wire);
    try std.testing.expectEqual(2, wire.writes);
}

test "an answer does not wait for the rest of a request that arrived in part" {
    const both = ok("text/plain", "55") ++ ok("text/plain", "75");
    var wire: Wire = undefined;
    // Part of the next head: the first answer is written before the rest is read.
    try converse(api, &.{ .{ .buffer = get_sum ++ post_sum[0..20] }, .{ .buffer = post_sum[20..] } }, &wire);
    try std.testing.expectEqual(2, wire.writes);
    try std.testing.expectEqualStrings(both, wire.text());
    // The whole next head and part of its body, which the handler reads.
    try converse(api, &.{ .{ .buffer = get_sum ++ post_sum[0 .. post_sum.len - 1] }, .{ .buffer = post_sum[post_sum.len - 1 ..] } }, &wire);
    try std.testing.expectEqual(2, wire.writes);
    try std.testing.expectEqualStrings(both, wire.text());
    // The same, with a body nobody reads: it is skipped before the answer.
    const unread = "POST /json HTTP/1.1\r\nHost: test\r\nContent-Length: 2\r\n\r\n20";
    try converse(api, &.{ .{ .buffer = get_sum ++ unread[0 .. unread.len - 1] }, .{ .buffer = unread[unread.len - 1 ..] } }, &wire);
    try std.testing.expectEqual(2, wire.writes);
    try std.testing.expectEqualStrings(ok("text/plain", "55") ++ empty("405 Method Not Allowed", .open), wire.text());
}

test "the connection ends when the peer asks to close it" {
    var wire: Wire = undefined;
    try converse(api, &.{.{ .buffer = "GET /sum?a=1 HTTP/1.1\r\nConnection: close\r\n\r\n" ++ get_sum }}, &wire);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 1\r\ncontent-type: text/plain\r\n\r\n1", wire.text());
}

test "an HTTP/1.0 request is answered and the connection closed" {
    try expectAnswer("HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n55", "GET /sum?a=13&b=42 HTTP/1.0\r\n\r\n");
}

test "a pipe that is done takes no further requests from its connection" {
    var wire: Wire = undefined;
    const two = pipe(.{
        take(2),
        http.status(.ok),
    });
    try converse(two, &.{.{ .buffer = times(3, get_sum) }}, &wire);
    try std.testing.expectEqualStrings(times(2, empty("200 OK", .open)), wire.text());
}

const Seen = struct { connections: usize = 0, requests: usize = 0 };

fn count(total: usize, _: http.Request) usize {
    return total + 1;
}

fn note(seen: *Seen, requests: usize) void {
    seen.connections += 1;
    seen.requests += requests;
}

test "the pipe is constructed for each connection and finished when it ends" {
    var seen: Seen = .{};
    var wires: [2]Wire = undefined;
    var first: Io.Reader = .fixed(times(3, get_sum));
    var second: Io.Reader = .fixed(times(2, get_sum));
    for (&wires) |*wire| wire.init();
    const transports = [_]http.Transport{
        .{ .reader = &first, .writer = &wires[0].writer },
        .{ .reader = &second, .writer = &wires[1].writer },
    };
    const counted = pipe(.{branch(.{
        .{http.status(.no_content)},
        .{
            fold(@as(usize, 0), count),
            forEach(note),
        },
    })});
    try program(fromSlice(&transports), .{http.serve(counted)}).run(.{&seen});
    try std.testing.expectEqual(Seen{ .connections = 2, .requests = 5 }, seen);
    try std.testing.expectEqualStrings(times(3, "HTTP/1.1 204 No Content\r\n\r\n"), wires[0].text());
    try std.testing.expectEqualStrings(times(2, "HTTP/1.1 204 No Content\r\n\r\n"), wires[1].text());
}

// ---------------------------------------------------------------------------
// Failures of a request
// ---------------------------------------------------------------------------

test "fail answers each error with its status and the connection goes on" {
    const cases = .{
        .{ "/bad", "400 Bad Request" },
        .{ "/missing", "404 Not Found" },
        .{ "/method", "405 Method Not Allowed" },
        .{ "/length", "411 Length Required" },
        .{ "/large", "413 Payload Too Large" },
        .{ "/expect", "417 Expectation Failed" },
        .{ "/other", "500 Internal Server Error" },
    };
    inline for (cases) |case| {
        var wire: Wire = undefined;
        try converse(api, &.{.{ .buffer = "GET " ++ case[0] ++ " HTTP/1.1\r\n\r\n" ++ get_sum }}, &wire);
        try std.testing.expectEqualStrings(empty(case[1], .open) ++ ok("text/plain", "55"), wire.text());
    }
}

test "a body that cannot be taken is refused and the connection closed" {
    const cases = .{
        // No framing on a method that has a body.
        .{ "POST /sum HTTP/1.1\r\n\r\n", "411 Length Required" },
        // More than the handler's buffer holds, by its length and by its chunks.
        .{ "POST /sum HTTP/1.1\r\nContent-Length: 9\r\n\r\n123456789", "413 Payload Too Large" },
        .{ "POST /sum HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n", "413 Payload Too Large" },
        // Two framings, a chunk that is none, a body where none belongs.
        .{ "POST /sum HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n20\r\n0\r\n\r\n", "400 Bad Request" },
        .{ "POST /sum HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n2X\r\n", "400 Bad Request" },
        .{ "GET /sum HTTP/1.1\r\nContent-Length: 2\r\n\r\n20", "400 Bad Request" },
        .{ "POST /sum HTTP/1.1\r\nContent-Length: 2\r\nExpect: a-miracle\r\n\r\n20", "417 Expectation Failed" },
    };
    inline for (cases) |case| {
        var wire: Wire = undefined;
        try converse(api, &.{.{ .buffer = case[0] ++ get_sum }}, &wire);
        try std.testing.expectEqualStrings(empty(case[1], .closed), wire.text());
    }
}

test "a body nobody read is skipped, or the connection closed where it cannot be" {
    const not_allowed = empty("405 Method Not Allowed", .open);
    // A body with a length is skipped.
    try expectAnswer(not_allowed ++ ok("text/plain", "55"), "POST /json HTTP/1.1\r\nContent-Length: 2\r\n\r\n20" ++ get_sum);
    // One the peer is still waiting to send is not asked for.
    try expectAnswer(empty("405 Method Not Allowed", .closed), "POST /json HTTP/1.1\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\n");
    // One without framing, or on a method that has none, hides the next request.
    try expectAnswer(empty("405 Method Not Allowed", .closed), "POST /json HTTP/1.1\r\n\r\n" ++ get_sum);
    // One that turns out not to be a body ends the connection where it stopped.
    try expectAnswer(empty("405 Method Not Allowed", .closed), "POST /json HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n2X\r\n" ++ get_sum);
    try expectAnswer(
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 27\r\ncontent-type: application/json\r\n\r\n{\"message\":\"Hello, World!\"}",
        "GET /json HTTP/1.1\r\nContent-Length: 2\r\n\r\n20" ++ get_sum,
    );
}

test "without fail, a handler's error fails the run" {
    var wire: Wire = undefined;
    try std.testing.expectError(error.NotFound, converse(.{routes}, &.{.{ .buffer = "GET /missing HTTP/1.1\r\n\r\n" }}, &wire));
}

// ---------------------------------------------------------------------------
// Failures of a connection
// ---------------------------------------------------------------------------

test "a head that does not parse is answered 400 and the connection closed" {
    try expectAnswer(empty("400 Bad Request", .closed), "NONSENSE\r\n\r\n" ++ get_sum);
    try expectAnswer(ok("text/plain", "55") ++ empty("400 Bad Request", .closed), get_sum ++ "GET /sum SPDY/9\r\n\r\n" ++ get_sum);
}

test "a head that does not fit is answered 431 and the connection closed" {
    try expectAnswer(empty("431 Request Header Fields Too Large", .closed), "GET /sum HTTP/1.1\r\nX-Padding: " ++ times(512, "x") ++ "\r\n\r\n");
}

test "a peer that leaves inside a head is not answered" {
    try expectAnswer(ok("text/plain", "55"), get_sum ++ "GET /sum HT");
}

/// A connection whose peer sent `request` and is gone before it was all read.
fn brokenAfter(request: []const u8, storage: []u8) Io.Reader {
    @memcpy(storage[0..request.len], request);
    var reader: Io.Reader = .failing;
    reader.buffer = storage;
    reader.end = request.len;
    return reader;
}

test "a connection that breaks fails the run, or is dropped by disconnected" {
    var storage: [4][256]u8 = undefined;
    var wires: [5]Wire = undefined;
    for (&wires) |*wire| wire.init();
    // Broken while a head is awaited, inside a head, and inside a body; and
    // one that ended inside a body without an error.
    var silent = brokenAfter("", &storage[0]);
    var in_head = brokenAfter("GET /sum HT", &storage[1]);
    var in_body = brokenAfter("POST /sum HTTP/1.1\r\nContent-Length: 2\r\n\r\n2", &storage[2]);
    var ended: Io.Reader = .fixed("POST /sum HTTP/1.1\r\nContent-Length: 2\r\n\r\n2");
    var fine: Io.Reader = .fixed(get_sum);
    const transports = [_]http.Transport{
        .{ .reader = &silent, .writer = &wires[0].writer },
        .{ .reader = &in_head, .writer = &wires[1].writer },
        .{ .reader = &in_body, .writer = &wires[2].writer },
        .{ .reader = &ended, .writer = &wires[3].writer },
        .{ .reader = &fine, .writer = &wires[4].writer },
    };
    try program(fromSlice(&transports), .{
        recover(http.disconnected),
        http.serve(api),
    }).run(.{});
    for (wires[0..4]) |*wire| try std.testing.expectEqualStrings("", wire.text());
    try std.testing.expectEqualStrings(ok("text/plain", "55"), wires[4].text());

    var again = brokenAfter("GET /sum HT", &storage[3]);
    const one: http.Transport = .{ .reader = &again, .writer = &wires[0].writer };
    try std.testing.expectError(error.ReadFailed, program(fromValue(one), .{http.serve(api)}).run(.{}));
}

test "an answer that cannot be written breaks the connection, not the run" {
    var first: Io.Reader = .fixed(get_sum);
    var second: Io.Reader = .fixed(get_sum);
    var full: Io.Writer = .fixed(&.{});
    var wire: Wire = undefined;
    wire.init();
    const transports = [_]http.Transport{
        .{ .reader = &first, .writer = &full },
        .{ .reader = &second, .writer = &wire.writer },
    };
    try program(fromSlice(&transports), .{
        recover(http.disconnected),
        http.serve(api),
    }).run(.{});
    try std.testing.expectEqualStrings(ok("text/plain", "55"), wire.text());

    var again: Io.Reader = .fixed(get_sum);
    const one: http.Transport = .{ .reader = &again, .writer = &full };
    try std.testing.expectError(error.WriteFailed, program(fromValue(one), .{http.serve(api)}).run(.{}));
}

test "disconnected lets every other error fail the run" {
    var wire: Wire = undefined;
    wire.init();
    var peer: Io.Reader = .fixed("GET /missing HTTP/1.1\r\n\r\n");
    const connection: http.Transport = .{ .reader = &peer, .writer = &wire.writer };
    try std.testing.expectError(error.NotFound, program(fromValue(connection), .{
        recover(http.disconnected),
        http.serve(.{routes}),
    }).run(.{}));
}

// ---------------------------------------------------------------------------
// Over a socket
// ---------------------------------------------------------------------------

/// Where a test learns that the server listens, and on which port.
const Ready = struct {
    port: u16 = 0,
    listening: Io.Event = .unset,
};
const Announced = struct {};

fn announce(listener: http.Listener, ready: *Ready) Announced {
    ready.port = listener.port();
    ready.listening.set(io);
    return .{};
}

const loopback: Io.net.IpAddress = .{ .ip4 = .loopback(0) };

/// Sends `request` to the server on a connection of its own and returns
/// everything it answers until it closes the connection.
fn ask(port: u16, request: []const u8, answer: []u8) ![]const u8 {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    try out.interface.writeAll(request);
    var in = stream.reader(io, &.{});
    return answer[0..try in.interface.readSliceShort(answer)];
}

test "connections are accepted from the listener and served by workers" {
    const Server = struct {
        const served = program(http.connections(), .{
            take(3),
            concurrent(2, .{
                recover(http.disconnected),
                http.serve(api),
            }),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(ready: *Ready) !void {
            return served.run(.{ io, ready });
        }
    };
    var ready: Ready = .{};
    var server = try io.concurrent(Server.run, .{&ready});
    defer server.cancel(io) catch {};
    try ready.listening.wait(io);

    var answer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n55",
        try ask(ready.port, "GET /sum?a=13&b=42 HTTP/1.1\r\nConnection: close\r\n\r\n", &answer),
    );
    try std.testing.expectEqualStrings(
        ok("text/plain", "55") ++ "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n75",
        try ask(ready.port, get_sum ++ "POST /sum?a=13&b=42 HTTP/1.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n20", &answer),
    );
    try std.testing.expectEqualStrings(empty("400 Bad Request", .closed), try ask(ready.port, "NONSENSE\r\n\r\n", &answer));
    // Three connections were taken: the source has ended and the workers with it.
    try server.await(io);
}

test "a server waiting for a request can be cancelled" {
    const Server = struct {
        // One loop on the calling task: the cancellation has to come out of
        // the read it interrupts, where `std` reports it as a failed read.
        const served = program(http.connections(), .{
            recover(http.disconnected),
            http.serve(api),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(ready: *Ready) !void {
            return served.run(.{ io, ready });
        }
    };
    var ready: Ready = .{};
    var server = try io.concurrent(Server.run, .{&ready});
    defer server.cancel(io) catch {};
    try ready.listening.wait(io);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(ready.port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    try out.interface.writeAll(get_sum);
    var in = stream.reader(io, &.{});
    var answer: [ok("text/plain", "55").len]u8 = undefined;
    try in.interface.readSliceAll(&answer);
    // The connection is kept alive: the server is in, or on its way to, the
    // read of the next request.
    try std.testing.expectError(error.Canceled, server.cancel(io));
}

test "a server whose workers hold open connections can be cancelled" {
    // The request to cancel is pending while the run retires and joins its
    // tasks, which `std.testing.io` can lose in Debug: a plain allocator.
    var backend: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer backend.deinit();
    const on = backend.io();
    const Server = struct {
        const served = program(http.connections(), .{
            concurrent(2, .{
                recover(http.disconnected),
                http.serve(api),
            }),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(with: Io, ready: *Ready) !void {
            return served.run(.{ with, ready });
        }
    };
    var ready: Ready = .{};
    var server = try on.concurrent(Server.run, .{ on, &ready });
    defer server.cancel(on) catch {};
    try ready.listening.wait(io);

    // Each worker has answered a request on a connection that stays open.
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(ready.port) };
    var peers: [2]Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (peers[0..opened]) |peer| peer.close(io);
    for (&peers) |*peer| {
        peer.* = try address.connect(io, .{ .mode = .stream });
        opened += 1;
        var out = peer.writer(io, &.{});
        try out.interface.writeAll(get_sum);
        var in = peer.reader(io, &.{});
        var answer: [ok("text/plain", "55").len]u8 = undefined;
        try in.interface.readSliceAll(&answer);
    }
    try std.testing.expectError(error.Canceled, server.cancel(on));
}

const Reached = struct { handler: Io.Event = .unset };

fn noteReached(reached: *Reached, _: http.Request) void {
    reached.handler.set(io);
}

test "a server skipping a body nobody read can be cancelled" {
    const Server = struct {
        // One loop on the calling task, as above. Here the read that is
        // interrupted is the one `std` makes to skip the body before the
        // answer, whose failure it does not report.
        const served = program(http.connections(), .{
            recover(http.disconnected),
            http.serve(.{
                tap(noteReached),
                http.status(.ok),
            }),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(ready: *Ready, reached: *Reached) !void {
            return served.run(.{ io, ready, reached });
        }
    };
    var ready: Ready = .{};
    var reached: Reached = .{};
    var server = try io.concurrent(Server.run, .{ &ready, &reached });
    defer server.cancel(io) catch {};
    try ready.listening.wait(io);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(ready.port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    // Three of ten bytes of body: the rest never comes.
    try out.interface.writeAll("POST /x HTTP/1.1\r\nHost: test\r\nContent-Length: 10\r\n\r\nabc");
    try reached.handler.wait(io);
    // The server is in, or on its way to, the read that skips the body.
    try std.testing.expectError(error.Canceled, server.cancel(io));
}

/// An `Io` that counts the connections accepted through it and how many of
/// those were closed. One at a time: its state is global.
const Sockets = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var handles: [8]Io.net.Socket.Handle = undefined;
    var accepted: std.atomic.Value(usize) = .init(0);
    var closed: std.atomic.Value(usize) = .init(0);
    var expected: usize = 0;
    /// Set once `expected` connections have been accepted.
    var all_accepted: Io.Event = .unset;

    fn over(under: Io, expect: usize) Io {
        inner = under;
        vtable = under.vtable.*;
        vtable.netAccept = accept;
        vtable.netClose = close;
        accepted.store(0, .seq_cst);
        closed.store(0, .seq_cst);
        expected = expect;
        all_accepted = .unset;
        return .{ .userdata = under.userdata, .vtable = &vtable };
    }

    fn accept(userdata: ?*anyopaque, server: Io.net.Socket.Handle, options: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
        const socket = try inner.vtable.netAccept(userdata, server, options);
        const index = accepted.load(.seq_cst);
        handles[index] = socket.handle;
        accepted.store(index + 1, .seq_cst);
        if (index + 1 == expected) all_accepted.set(inner);
        return socket;
    }

    fn close(userdata: ?*anyopaque, sockets: []const Io.net.Socket) void {
        for (sockets) |socket| for (handles[0..accepted.load(.seq_cst)]) |handle| {
            if (socket.handle == handle) _ = closed.fetchAdd(1, .seq_cst);
        };
        inner.vtable.netClose(userdata, sockets);
    }
};

test "cancelling a server closes the connections no worker had taken" {
    // A request to cancel is pending while tasks are joined: a plain allocator.
    var backend: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer backend.deinit();
    const on = Sockets.over(backend.io(), 3);
    const Server = struct {
        const served = program(http.connections(), .{
            concurrent(1, .{
                recover(http.disconnected),
                http.serve(api),
            }),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(with: Io, ready: *Ready) !void {
            return served.run(.{ with, ready });
        }
    };
    var ready: Ready = .{};
    var server = try on.concurrent(Server.run, .{ on, &ready });
    defer server.cancel(on) catch {};
    try ready.listening.wait(io);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(ready.port) };
    var peers: [3]Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (peers[0..opened]) |peer| peer.close(io);
    // The one worker has answered the first peer and holds its connection.
    peers[0] = try address.connect(io, .{ .mode = .stream });
    opened += 1;
    var out = peers[0].writer(io, &.{});
    try out.interface.writeAll(get_sum);
    var in = peers[0].reader(io, &.{});
    var answer: [ok("text/plain", "55").len]u8 = undefined;
    try in.interface.readSliceAll(&answer);
    // Two more are accepted and wait: one in the worker's queue, one with
    // the source, which cannot put it there yet.
    for (peers[1..]) |*peer| {
        peer.* = try address.connect(io, .{ .mode = .stream });
        opened += 1;
    }
    try Sockets.all_accepted.wait(io);

    try std.testing.expectError(error.Canceled, server.cancel(on));
    try std.testing.expectEqual(@as(usize, 3), Sockets.closed.load(.seq_cst));
}

test "with room for one waiting connection, every connection is still served" {
    const Server = struct {
        const served = program(http.connections(), .{
            take(3),
            concurrent(1, .{
                recover(http.disconnected),
                http.serve(api),
            }),
        }).provide(.{
            http.listen(loopback, .{ .pending = 1 }),
            resource(announce, null),
        });

        fn run(ready: *Ready) !void {
            return served.run(.{ io, ready });
        }
    };
    var ready: Ready = .{};
    var server = try io.concurrent(Server.run, .{&ready});
    defer server.cancel(io) catch {};
    try ready.listening.wait(io);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(ready.port) };
    const closing = "GET /sum?a=13&b=42 HTTP/1.1\r\nConnection: close\r\n\r\n";
    const closed = "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n55";
    // The worker answers the first peer and stays with its open connection.
    const first = try address.connect(io, .{ .mode = .stream });
    var first_open = true;
    defer if (first_open) first.close(io);
    var out = first.writer(io, &.{});
    try out.interface.writeAll(get_sum);
    var in = first.reader(io, &.{});
    var answer: [ok("text/plain", "55").len]u8 = undefined;
    try in.interface.readSliceAll(&answer);

    // Two more peers ask. The first of them fills the listener's room; the
    // second is accepted only once that room is free again.
    var others: [2]Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (others[0..opened]) |peer| peer.close(io);
    for (&others) |*peer| {
        peer.* = try address.connect(io, .{ .mode = .stream });
        opened += 1;
        var asking = peer.writer(io, &.{});
        try asking.interface.writeAll(closing);
    }
    first.close(io);
    first_open = false;
    for (others) |peer| {
        var answering = peer.reader(io, &.{});
        var got: [256]u8 = undefined;
        try std.testing.expectEqualStrings(closed, got[0..try answering.interface.readSliceShort(&got)]);
    }
    try server.await(io);
}

/// An `Io` whose first accept finds that the peer has already given up.
const AbortedOnce = struct {
    var inner: Io = undefined;
    var vtable: Io.VTable = undefined;
    var aborted: std.atomic.Value(bool) = .init(false);

    fn over(under: Io) Io {
        inner = under;
        vtable = under.vtable.*;
        vtable.netAccept = accept;
        aborted.store(false, .seq_cst);
        return .{ .userdata = under.userdata, .vtable = &vtable };
    }

    fn accept(userdata: ?*anyopaque, server: Io.net.Socket.Handle, options: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
        if (!aborted.swap(true, .seq_cst)) return error.ConnectionAborted;
        return inner.vtable.netAccept(userdata, server, options);
    }
};

test "a connection given up before it was accepted is skipped" {
    const Server = struct {
        const served = program(http.connections(), .{
            take(1),
            http.serve(api),
        }).provide(.{
            http.listen(loopback, .{}),
            resource(announce, null),
        });

        fn run(ready: *Ready) !void {
            return served.run(.{ AbortedOnce.over(io), ready });
        }
    };
    var ready: Ready = .{};
    var server = try io.concurrent(Server.run, .{&ready});
    defer server.cancel(io) catch {};
    try ready.listening.wait(io);

    var answer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\ncontent-type: text/plain\r\n\r\n55",
        try ask(ready.port, "GET /sum?a=13&b=42 HTTP/1.1\r\nConnection: close\r\n\r\n", &answer),
    );
    try server.await(io);
    try std.testing.expect(AbortedOnce.aborted.load(.seq_cst));
}
