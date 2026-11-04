const std = @import("std");
const zrx = @import("zrx");
const a = std.testing.allocator;
const io = std.testing.io;
const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
const Settings = struct { ready: *zrx.HttpReady, count: usize = 0, fail: bool = false, invalid: bool = false };
const Probe = struct { acquired: bool = false, released: bool = false, calls: usize = 0, wrapped: usize = 0, requests: usize = 0 };
const Lease = struct { probe: *Probe };
const ReadyServer = struct { server: *zrx.HttpServer };

fn acquire(p: *Probe, _: void) Lease {
    p.acquired = true;
    return .{ .probe = p };
}
fn release(lease: Lease) void {
    lease.probe.released = true;
}
fn configure(settings: Settings, lease: Lease) !zrx.HttpServerConfig {
    std.debug.assert(lease.probe.acquired and !lease.probe.released);
    lease.probe.calls += 1;
    if (settings.fail) return error.ProviderFailed;
    return .{
        .address = .{ .ip4 = .loopback(0) },
        .connection_budget = settings.count,
        .head_bytes = if (settings.invalid) 0 else 1024,
        .ready = settings.ready,
    };
}
fn wrap(server: *zrx.HttpServer, p: *Probe, _: void) ReadyServer {
    std.debug.assert(server.address().getPort() != 0 and !p.released);
    p.wrapped += 1;
    return .{ .server = server };
}
fn failWrap(_: *zrx.HttpServer, _: void) error{WrapperFailed}!ReadyServer {
    return error.WrapperFailed;
}
fn reply(lease: Lease, request: zrx.HttpRequest) zrx.HttpResponse {
    std.debug.assert(!lease.probe.released);
    lease.probe.requests += 1;
    return request.response(.{ .body = "configured\n" });
}
const program = zrx.pipe(zrx.httpRequests(ReadyServer), .{
    zrx.map(reply), zrx.respondHttp(),
});

test "HTTP provider is cold called once per run and retains managed dependencies" {
    inline for (.{ false, true }) |fail| {
        var ready: zrx.HttpReady = .{};
        var p: Probe = .{};
        const settings: Settings = .{ .ready = &ready, .fail = fail };
        try std.testing.expectEqual(@as(usize, 0), p.calls);
        const result = zrx.run(.{
            a, io, settings, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
        }, .{program});
        if (fail) try std.testing.expectError(error.ProviderFailed, result) else try result;
        try std.testing.expect(p.released);
        try std.testing.expectEqual(@as(usize, 1), p.calls);
        try std.testing.expectEqual(!fail, ready.ready.isSet());
        try std.testing.expectEqual(@as(usize, if (fail) 0 else 1), p.wrapped);
        if (!fail) {
            var rebound = try ready.address.listen(io, .{});
            rebound.deinit(io);
        }
    }
}

test "unreachable managed server stays cold without requiring its provider services" {
    try zrx.run(.{ a, io, zrx.httpServer(configure) }, .{
        zrx.pipe(zrx.fromValue(@as(u8, 1)), .{zrx.discard()}),
    });
}

test "deriveResource exposes a nominal server role with delegated ownership" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    try zrx.run(.{
        a, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.deriveResource(ReadyServer, zrx.httpServer(configure)),
    }, .{program});
    try std.testing.expect(p.released and p.calls == 1 and p.wrapped == 0);
    var rebound = try ready.address.listen(io, .{});
    rebound.deinit(io);
}

test "invalid provider result fails before listening or wrapper effects" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    try std.testing.expectError(error.InvalidHttpConfig, zrx.run(.{
        a, io, Settings{ .ready = &ready, .invalid = true }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
    }, .{program}));
    try std.testing.expect(!ready.ready.isSet() and p.released and p.wrapped == 0);
}

fn ignore(_: []const zrx.HttpRequest) void {}
test "unsupported HTTP retention rejects before resolving provider or acquiring dependencies" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    const unsafe = zrx.pipe(zrx.httpRequests(ReadyServer), .{zrx.collectThen(ignore)});
    try std.testing.expectError(error.UnsupportedHttpComposition, zrx.run(.{
        a, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
    }, .{unsafe}));
    try std.testing.expectEqualDeep(Probe{}, p);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    try zrx.run(.{
        allocator, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
    }, .{program});
}
test "configured HTTP cleans every partial preparation and acquisition allocation" {
    try std.testing.checkAllAllocationFailures(a, allocationFixture, .{});
}

test "configured HTTP serves a real finite loopback peer before releasing dependencies" {
    const Server = struct {
        ready: zrx.HttpReady = .{},
        probe: Probe = .{},
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            try zrx.run(.{
                a, io, Settings{ .ready = &self.ready, .count = 1 }, &self.probe, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
            }, .{program});
        }
    };
    var server: Server = .{};
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try server.ready.ready.waitTimeout(io, timeout);
    const Peer = struct {
        address: std.Io.net.IpAddress,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            const connection = try self.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer connection.close(io);
            var write_buffer: [128]u8 = undefined;
            var writer = connection.writer(io, &write_buffer);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nhost: local\r\n\r\n");
            try writer.interface.flush();
            var read_buffer: [512]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            const bytes = try reader.interface.allocRemaining(a, .limited(1024));
            defer a.free(bytes);
            try std.testing.expect(std.mem.startsWith(u8, bytes, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expect(std.mem.endsWith(u8, bytes, "\r\n\r\nconfigured\n"));
        }
    };
    var peer: Peer = .{ .address = server.ready.address };
    var client = try io.concurrent(Peer.execute, .{&peer});
    defer client.cancel(io) catch {};
    try peer.done.waitTimeout(io, timeout);
    try client.await(io);
    try server.done.waitTimeout(io, timeout);
    try task.await(io);
    try std.testing.expect(server.probe.released and server.probe.requests == 1);
}

test "custom wrapper failure releases its acquired server and dependencies" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    try std.testing.expectError(error.WrapperFailed, zrx.run(.{
        a, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, failWrap, null),
    }, .{program}));
    try std.testing.expect(ready.ready.isSet() and p.released and p.requests == 0);
    var rebound = try ready.address.listen(io, .{});
    rebound.deinit(io);
}

test "repeated source descriptions of one server service reject fanout before acquisition" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    try std.testing.expectError(error.UnsupportedHttpFanout, zrx.run(.{
        a, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null),
    }, .{ program, program }));
    try std.testing.expectEqualDeep(Probe{}, p);
}

const Alias = struct { server: *zrx.HttpServer };
fn alias(server: *zrx.HttpServer, _: void) Alias {
    return .{ .server = server };
}
test "distinct server role aliases reject concurrent serving before request activation" {
    var ready: zrx.HttpReady = .{};
    var p: Probe = .{};
    const other = zrx.pipe(zrx.httpRequests(Alias), .{ zrx.map(reply), zrx.respondHttp() });
    try std.testing.expectError(error.HttpServerInUse, zrx.run(.{
        a, io, Settings{ .ready = &ready }, &p, zrx.resource({}, acquire, release), zrx.httpServer(configure), zrx.resource({}, wrap, null), zrx.resource({}, alias, null),
    }, .{ program, other }));
    try std.testing.expect(p.released and p.calls == 1 and p.requests == 0);
    var rebound = try ready.address.listen(io, .{});
    rebound.deinit(io);
}

fn emptyReply(request: zrx.HttpRequest) zrx.HttpResponse {
    return request.response(.{});
}
test "borrowed HTTP owner is not released by run and can be reacquired fresh" {
    var owner = zrx.HttpServer.init(a, .{ .address = .{ .ip4 = .loopback(0) }, .connection_budget = 0 });
    for (0..2) |_| {
        try owner.acquire(io);
        defer owner.release(io);
        try zrx.run(.{ a, io, &owner }, .{
            zrx.pipe(zrx.httpRequests(*zrx.HttpServer), .{ zrx.map(emptyReply), zrx.respondHttp() }),
        });
        if (owner.address().listen(io, .{})) |listener| {
            var unexpected = listener;
            unexpected.deinit(io);
            return error.BorrowedListenerWasReleased;
        } else |err| try std.testing.expectEqual(error.AddressInUse, err);
    }
}
