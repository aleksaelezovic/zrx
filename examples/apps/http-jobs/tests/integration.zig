const std = @import("std");
const builtin = @import("builtin");
const zrx = @import("zrx");
const app = @import("app");
const peer = @import("peer.zig");
const allocator = peer.allocator;
const io = peer.io;
const Store = app.store.Store;

const Server = struct {
    settings: app.commands.Config,
    store: *Store,
    ready: zrx.HttpReady = .{},
    stop: std.Io.Event = .unset,
    done: std.Io.Event = .unset,

    fn execute(self: *Server) !void {
        defer self.done.set(io);
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const file = try temp.dir.createFile(io, "console", .{});
        defer file.close(io);
        try zrx.run(.{
            allocator,
            io,
            self.settings,
            self.store,
            app.resources.server(.{ .ready = &self.ready, .stop = &self.stop, .console = file }),
        }, .{app.composition.program});
        const actual = try temp.dir.readFileAlloc(io, "console", allocator, .limited(1024));
        defer allocator.free(actual);
        const expected = try std.fmt.allocPrint(allocator, "ready http://{f}\n", .{self.ready.address});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
};

test "real graph records bodies routes failures enforces injected limits and shuts down" {
    try peer.bounded(graphScenario, .{});
}

fn graphScenario() !void {
    const Case = struct { wire: []const u8, status: []const u8, body: []const u8, extra: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .wire = peer.post(peer.valid), .status = "201 Created", .body = peer.recorded, .extra = "\r\nlocation: /jobs/1\r\n" },
        .{ .wire = "GET /jobs/1 HTTP/1.1\r\nhost: local\r\n\r\n", .status = "200 OK", .body = peer.recorded },
        .{ .wire = "GET /jobs/2 HTTP/1.1\r\n\r\n", .status = "404 Not Found", .body = "{\"error\":\"not_found\"}\n" },
        .{ .wire = "GET /jobs/01 HTTP/1.1\r\n\r\n", .status = "400 Bad Request", .body = "{\"error\":\"invalid_id\"}\n" },
        .{ .wire = "GET /missing HTTP/1.1\r\n\r\n", .status = "404 Not Found", .body = "{\"error\":\"not_found\"}\n" },
        .{ .wire = "GET /jobs?x=1 HTTP/1.1\r\n\r\n", .status = "404 Not Found", .body = "{\"error\":\"not_found\"}\n" },
        .{ .wire = "GET /jobs%2F1 HTTP/1.1\r\n\r\n", .status = "404 Not Found", .body = "{\"error\":\"not_found\"}\n" },
        .{ .wire = "GET /jobs/1?x=1 HTTP/1.1\r\n\r\n", .status = "400 Bad Request", .body = "{\"error\":\"invalid_id\"}\n" },
        .{ .wire = "POST /jobs/invalid HTTP/1.1\r\n\r\n", .status = "400 Bad Request", .body = "{\"error\":\"invalid_id\"}\n" },
        .{ .wire = "GET /jobs/1/extra HTTP/1.1\r\n\r\n", .status = "400 Bad Request", .body = "{\"error\":\"invalid_id\"}\n" },
        .{ .wire = "GET /jobs HTTP/1.1\r\n\r\n", .status = "405 Method Not Allowed", .body = "{\"error\":\"method_not_allowed\"}\n", .extra = "\r\nallow: POST\r\n" },
        .{ .wire = "POST /jobs/1 HTTP/1.1\r\n\r\n", .status = "405 Method Not Allowed", .body = "{\"error\":\"method_not_allowed\"}\n", .extra = "\r\nallow: GET\r\n" },
        .{ .wire = "POST /jobs HTTP/1.1\r\ncontent-length: 0\r\n\r\n", .status = "415 Unsupported Media Type", .body = "{\"error\":\"expected_json\"}\n" },
        .{ .wire = "POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\nContent-Type: application/json\r\ncontent-length: 0\r\n\r\n", .status = "415 Unsupported Media Type", .body = "{\"error\":\"expected_json\"}\n" },
        .{ .wire = "POST /jobs HTTP/1.1\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 0\r\n\r\n", .status = "415 Unsupported Media Type", .body = "{\"error\":\"expected_json\"}\n" },
        .{ .wire = "POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ncontent-encoding: identity\r\ncontent-length: 0\r\n\r\n", .status = "415 Unsupported Media Type", .body = "{\"error\":\"expected_json\"}\n" },
        .{ .wire = std.fmt.comptimePrint("POST /jobs HTTP/1.1\r\nCONTENT-TYPE: APPLICATION/JSON\r\ncontent-length: {d}\r\n\r\n{s}", .{ peer.valid.len, peer.valid }), .status = "503 Service Unavailable", .body = "{\"error\":\"store_full\"}\n" },
        .{ .wire = peer.post("{bad"), .status = "400 Bad Request", .body = "{\"error\":\"invalid_job\"}\n" },
        .{ .wire = peer.post("{\"label\":\"bad space\",\"values\":[1]}"), .status = "400 Bad Request", .body = "{\"error\":\"invalid_job\"}\n" },
        .{ .wire = peer.post("{\"label\":\"x\",\"values\":[1,2,3,4]}"), .status = "400 Bad Request", .body = "{\"error\":\"invalid_job\"}\n" },
        .{ .wire = peer.post("{\"label\":\"x\",\"values\":[1000001]}"), .status = "400 Bad Request", .body = "{\"error\":\"invalid_job\"}\n" },
        .{ .wire = "POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: 129\r\nexpect: 100-continue\r\n\r\n", .status = "413 Payload Too Large", .body = "{\"error\":\"body_too_large\"}\n" },
        .{ .wire = peer.post("{\"label\":\"second\",\"values\":[8]}"), .status = "503 Service Unavailable", .body = "{\"error\":\"store_full\"}\n" },
        .{ .wire = "GET /jobs/1 HTTP/1.1\r\n\r\n", .status = "200 OK", .body = peer.recorded },
    };
    var store = try Store.init(allocator, 1);
    defer store.deinit(allocator);
    var server: Server = .{ .settings = .{
        .connections = cases.len,
        .max_jobs = 1,
        .body_bytes = 128,
        .max_values = 3,
    }, .store = &store };
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.wait(io);
    for (cases) |case| {
        const result = try peer.exchange(server.ready.address, case.wire);
        defer allocator.free(result);
        try peer.expectResponse(result, case.status, case.body);
        if (case.extra) |extra| try peer.contains(result, extra);
    }
    try server.done.wait(io);
    try task.await(io);
    try std.testing.expectEqual(@as(usize, 1), store.len);
    try std.testing.expectEqual(@as(i64, 4), (try store.lookup(1)).job.result);
    try peer.expectClosed(server.ready.address);
}

test "chunked actual body and cumulative configured bound" {
    try peer.bounded(chunkedScenario, .{});
}

test "truncated and malformed body framing are scoped client failures" {
    try peer.bounded(invalidBodyScenario, .{});
}

fn invalidBodyScenario() !void {
    var store = try Store.init(allocator, 1);
    defer store.deinit(allocator);
    var server: Server = .{ .settings = .{ .connections = 2, .max_jobs = 1 }, .store = &store };
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.wait(io);
    const truncated = try peer.exchangeEnding(server.ready.address, "POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: 10\r\n\r\n{}", true);
    defer allocator.free(truncated);
    try peer.expectResponse(truncated, "400 Bad Request", "{\"error\":\"invalid_body\"}\n");
    const malformed = try peer.exchange(server.ready.address, "POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n2\r\nabxx");
    defer allocator.free(malformed);
    try peer.expectResponse(malformed, "400 Bad Request", "{\"error\":\"invalid_body\"}\n");
    try server.done.wait(io);
    try task.await(io);
    try std.testing.expectEqual(@as(usize, 0), store.len);
}

fn chunkedScenario() !void {
    var store = try Store.init(allocator, 2);
    defer store.deinit(allocator);
    var server: Server = .{ .settings = .{ .connections = 2, .max_jobs = 2, .body_bytes = peer.valid.len }, .store = &store };
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.wait(io);
    const wire = std.fmt.comptimePrint("POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ peer.valid.len, peer.valid });
    const result = try peer.exchange(server.ready.address, wire);
    defer allocator.free(result);
    try peer.expectResponse(result, "201 Created", peer.recorded);
    // One extra body byte is rejected even across separate chunks.
    const excess = std.fmt.comptimePrint("POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ntransfer-encoding: chunked\r\n\r\n{x}\r\n{s}\r\n1\r\n \r\n0\r\n\r\n", .{ peer.valid.len, peer.valid });
    const failure = try peer.exchange(server.ready.address, excess);
    defer allocator.free(failure);
    try peer.expectResponse(failure, "413 Payload Too Large", "{\"error\":\"body_too_large\"}\n");
    try server.done.wait(io);
    try task.await(io);
    try std.testing.expectEqual(@as(usize, 1), store.len);
}

test "graceful stop and parent cancellation join idle admission" {
    inline for (.{ false, true }) |cancel| try peer.bounded(stopScenario, .{cancel});
}

fn stopScenario(cancel: bool) !void {
    var store = try Store.init(allocator, 1);
    defer store.deinit(allocator);
    var server: Server = .{ .settings = .{ .connections = null, .max_jobs = 1 }, .store = &store };
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.wait(io);
    if (cancel) {
        try std.testing.expectError(error.Canceled, task.cancel(io));
    } else {
        server.stop.set(io);
        try server.done.wait(io);
        try task.await(io);
    }
    var rebound = try server.ready.address.listen(io, .{});
    rebound.deinit(io);
    try std.testing.expectEqual(@as(usize, 0), store.len);
}

test "acquisition failure remains control flow without readiness or effects" {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    var store = try Store.init(allocator, 1);
    defer store.deinit(allocator);
    const settings: app.commands.Config = .{ .port = listener.socket.address.getPort(), .connections = 1, .max_jobs = 1 };
    var server: Server = .{ .settings = settings, .store = &store };
    try std.testing.expectError(error.AddressInUse, server.execute());
    try std.testing.expect(!server.ready.ready.isSet());
    try std.testing.expectEqual(@as(usize, 0), store.len);
}

fn allocationFixture(a: std.mem.Allocator) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "console", .{});
    defer file.close(io);
    const args: std.process.Args = switch (builtin.os.tag) {
        .windows => .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("http-jobs serve 0 0 2") },
        else => .{ .vector = &.{ "http-jobs", "serve", "0", "0", "2" } },
    };
    try zrx.run(.{
        a,
        io,
        app.resources.configuration(args),
        app.resources.store(),
        app.resources.server(.{ .console = file }),
    }, .{app.composition.program});
}

test "all cold allocation failures clean up app and graph storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFixture, .{});
}

test "cancel during an actual body read joins the request without storing or replying" {
    try peer.bounded(cancelBodyScenario, .{});
}

fn cancelBodyScenario() !void {
    var store = try Store.init(allocator, 1);
    defer store.deinit(allocator);
    var server: Server = .{ .settings = .{ .connections = 1, .max_jobs = 1 }, .store = &store };
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.wait(io);
    const Client = struct {
        address: std.Io.net.IpAddress,
        continued: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            const connection = try self.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer connection.close(io);
            var buffer: [256]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("POST /jobs HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: 30\r\nexpect: 100-continue\r\n\r\n");
            try writer.interface.flush();
            var reader = connection.reader(io, &buffer);
            var continuation: ["HTTP/1.1 100 Continue\r\n\r\n".len]u8 = undefined;
            try reader.interface.readSliceAll(&continuation);
            try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", &continuation);
            self.continued.set(io);
            // Cancellation closes this scope; no synthetic error response.
            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
        }
    };
    var client: Client = .{ .address = server.ready.address };
    var client_task = try io.concurrent(Client.execute, .{&client});
    defer client_task.cancel(io) catch {};
    try client.continued.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try client_task.await(io);
    try std.testing.expectEqual(@as(usize, 0), store.len);
    try peer.expectClosed(server.ready.address);
}
