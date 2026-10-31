const std = @import("std");
const zrx = @import("zrx");
const echo = @import("http_echo");
const httpRequests = zrx.httpRequests;
const respondHttp = zrx.respondHttp;
const sendHttpResponse = zrx.sendHttpResponse;
const pipe = zrx.pipe;
const each = zrx.each;
const forEach = zrx.forEach;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const filter = zrx.filter;
const run = zrx.run;
const Request = zrx.HttpRequest;
const Response = zrx.HttpResponse;
const allocator = std.testing.allocator;
const io = std.testing.io;
const watchdog: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

fn config() zrx.HttpServerConfig {
    return .{ .address = .{ .ip4 = .loopback(0) }, .connection_budget = 1 };
}

// All network waits run in cancelable tasks. On any assertion/timeout both
// sides are joined before their borrowed fixture storage goes out of scope.
fn exchange(comptime handler: anytype, options: zrx.HttpServerConfig, bytes: []const u8, after_continue: ?[]const u8) ![]u8 {
    return exchangePeer(handler, options, bytes, after_continue, false);
}

fn exchangePeer(comptime handler: anytype, options: zrx.HttpServerConfig, bytes: []const u8, after_continue: ?[]const u8, close_send: bool) ![]u8 {
    return exchangeBound(handler, options, bytes, after_continue, close_send, .{});
}

fn exchangeBound(comptime handler: anytype, options: zrx.HttpServerConfig, bytes: []const u8, after_continue: ?[]const u8, close_send: bool, bindings: anytype) ![]u8 {
    const Server = struct {
        options: zrx.HttpServerConfig,
        bindings: @TypeOf(bindings),
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            if (@TypeOf(handler) == @TypeOf(null)) {
                try echo.execute(allocator, io, self.options);
            } else {
                const incoming = httpRequests(self.options);
                const transform = if (@TypeOf(handler) == type) handler.handle else handler;
                const replies = if (comptime @TypeOf(handler) == type and @hasDecl(handler, "operator"))
                    pipe(&incoming, .{handler.operator})
                else
                    pipe(&incoming, .{each(transform)});
                if (comptime @TypeOf(handler) == type and !@hasDecl(handler, "terminal")) {
                    try run(.{ allocator, io } ++ self.bindings, .{replies});
                } else {
                    const terminal = if (@TypeOf(handler) == type) handler.terminal else respondHttp();
                    try run(.{ allocator, io } ++ self.bindings, .{pipe(&replies, .{terminal})});
                }
            }
        }
    };
    var ready: zrx.HttpReady = .{};
    var server: Server = .{ .options = options, .bindings = bindings };
    server.options.ready = &ready;
    var task = try io.concurrent(Server.execute, .{&server});
    defer task.cancel(io) catch {};
    try ready.ready.waitTimeout(io, watchdog);
    const Peer = struct {
        address: std.Io.net.IpAddress,
        bytes: []const u8,
        body: ?[]const u8,
        stop: ?*std.Io.Event,
        close_send: bool,
        result: ?[]u8 = null,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            const connection = try self.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer connection.close(io);
            var write_buffer: [256]u8 = undefined;
            var writer = connection.writer(io, &write_buffer);
            try writer.interface.writeAll(self.bytes);
            try writer.interface.flush();
            var read_buffer: [1024]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            if (self.body) |body| {
                var continuation: ["HTTP/1.1 100 Continue\r\n\r\n".len]u8 = undefined;
                try reader.interface.readSliceAll(&continuation);
                try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", &continuation);
                if (self.stop) |stop| stop.set(io);
                try writer.interface.writeAll(body);
                try writer.interface.flush();
            }
            if (self.close_send) try connection.shutdown(io, .send);
            // Leave the sending half open. The server must close without EOF.
            self.result = reader.interface.allocRemaining(allocator, .limited(200000)) catch |err| blk: {
                // Closing an ingress-rejected socket with unread bytes can
                // produce reset rather than FIN on the client's platform.
                if (reader.err) |cause| {
                    if (cause == error.ConnectionResetByPeer) break :blk try allocator.alloc(u8, 0);
                }
                return err;
            };
        }
    };
    var peer: Peer = .{
        .address = ready.address,
        .bytes = bytes,
        .body = after_continue,
        .stop = options.stop,
        .close_send = close_send,
    };
    var client = try io.concurrent(Peer.execute, .{&peer});
    defer client.cancel(io) catch {};
    errdefer if (peer.result) |result| allocator.free(result);
    try peer.done.waitTimeout(io, watchdog);
    try client.await(io);
    try server.done.waitTimeout(io, watchdog);
    try task.await(io);
    return peer.result.?;
}

fn expectContains(bytes: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, bytes, expected) != null);
}

test "actual example graph serves health HEAD echo chunked and unread body" {
    const cases = .{
        .{ "GET /health HTTP/1.1\r\nhost: local\r\n\r\n", "200 OK\r\n", "ok\n" },
        .{ "HEAD /health HTTP/1.0\r\n\r\n", "200 OK\r\n", "" },
        .{ "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\nhello", "200 OK\r\n", "hello" },
        .{ "POST /echo HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n", "200 OK\r\n", "hello" },
        .{ "POST /missing HTTP/1.1\r\ncontent-length: 100\r\nexpect: 100-continue\r\n\r\n", "404 Not Found\r\n", "not found\n" },
    };
    inline for (cases) |case| {
        const result = try exchange(null, config(), case[0], null);
        defer allocator.free(result);
        try expectContains(result, case[1]);
        const body_start = std.mem.find(u8, result, "\r\n\r\n").? + 4;
        try std.testing.expectEqualStrings(case[2], result[body_start..]);
        try std.testing.expect(std.mem.find(u8, result, "100 Continue") == null);
    }
}

test "body fetch sends Expect continuation only when requested" {
    const result = try exchange(null, config(), "POST /echo HTTP/1.1\r\ncontent-length: 5\r\nexpect: 100-continue\r\n\r\n", "hello");
    defer allocator.free(result);
    try expectContains(result, "200 OK\r\n");
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nhello"));
}

const Greeting = struct { body: []const u8 };
fn configuredHandler(greeting: Greeting, request: Request) Response {
    return request.response(.{ .body = greeting.body });
}
test "HTTP handler services are injected while the request remains ordinary data" {
    const result = try exchangeBound(configuredHandler, config(), "GET / HTTP/1.1\r\n\r\n", null, false, .{
        Greeting{ .body = "injected\n" },
    });
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\ninjected\n"));
}

fn remainder(request: Request) Response {
    const reader = request.bodyReader() catch return request.response(.{ .status = .bad_request });
    const first = reader.takeByte() catch return request.response(.{ .status = .bad_request });
    const body = request.readRemainingBody() catch |err| return request.response(.{
        .status = if (err == error.HttpBodyTooLarge) .payload_too_large else .bad_request,
    });
    if (first != 'a' or !std.mem.eql(u8, request.target, "/remain") or
        !std.mem.eql(u8, request.headers[0].name, "x-test"))
        return request.response(.{ .status = .internal_server_error });
    const again = request.readRemainingBody() catch return request.response(.{ .status = .bad_request });
    if (again.len != 0) return request.response(.{ .status = .internal_server_error });
    return request.response(.{ .body = body });
}

test "byte and whole-body helpers share one cursor and preserve copied headers" {
    const result = try exchange(remainder, config(), "POST /remain HTTP/1.1\r\nx-test: stable\r\ncontent-length: 3\r\n\r\nabc", null);
    defer allocator.free(result);
    try expectContains(result, "200 OK\r\n");
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nbc"));
}

test "body limits cover declared lengths and cumulative chunked reads" {
    var options = config();
    options.request_body_bytes = 3;
    inline for (.{
        "POST /echo HTTP/1.1\r\ncontent-length: 4\r\nexpect: 100-continue\r\n\r\n",
        "POST /echo HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n4\r\nabcd\r\n0\r\n\r\n",
    }) |wire| {
        const result = try exchange(null, options, wire, null);
        defer allocator.free(result);
        try expectContains(result, "413 Payload Too Large\r\n");
        try std.testing.expect(std.mem.find(u8, result, "100 Continue") == null);
    }
    const result = try exchange(remainder, options, "POST /remain HTTP/1.1\r\nx-test: stable\r\ntransfer-encoding: chunked\r\n\r\n4\r\nabcd\r\n0\r\n\r\n", null);
    defer allocator.free(result);
    try expectContains(result, "413 Payload Too Large\r\n");
}

test "exact and zero body limits accept successful framed end" {
    var options = config();
    options.request_body_bytes = 3;
    inline for (.{
        "POST /echo HTTP/1.1\r\ncontent-length: 3\r\n\r\nabc",
        "POST /echo HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
    }) |wire| {
        const result = try exchange(null, options, wire, null);
        defer allocator.free(result);
        try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nabc"));
    }
    options.request_body_bytes = 0;
    const result = try exchange(null, options, "POST /echo HTTP/1.1\r\ncontent-length: 0\r\n\r\n", null);
    defer allocator.free(result);
    try expectContains(result, "200 OK\r\n");
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\n"));
}

fn copiedResponse(request: Request) Response {
    var bytes = [_]u8{ 'c', 'o', 'p', 'y' };
    var value = [_]u8{ 'k', 'e', 'p', 't' };
    const response = request.response(.{ .body = &bytes, .headers = &.{.{ .name = "x-copy", .value = &value }} });
    @memset(&bytes, 'x');
    @memset(&value, 'y');
    return response;
}

test "constructed responses copy callback-local body and header storage" {
    const result = try exchange(copiedResponse, config(), "GET / HTTP/1.1\r\n\r\n", null);
    defer allocator.free(result);
    try expectContains(result, "x-copy: kept\r\n");
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\ncopy"));
}

test "invalid config and fanout fail before listener acquisition" {
    var options = config();
    options.head_bytes = 0;
    const incoming = httpRequests(options);
    const replies = pipe(&incoming, .{each(echo.healthResponse)});
    try std.testing.expectError(error.InvalidHttpConfig, run(.{ allocator, io }, .{pipe(&replies, .{respondHttp()})}));
    const source = httpRequests(config());
    const shared = pipe(&source, .{each(echo.healthResponse)});
    try std.testing.expectError(error.UnsupportedHttpFanout, run(.{ allocator, io }, .{
        pipe(&shared, .{respondHttp()}), pipe(&shared, .{respondHttp()}),
    }));
}

test "zero budget acquires and releases listener without accepting" {
    var options = config();
    options.connection_budget = 0;
    try echo.execute(allocator, io, options);
}

test "graceful stop drains the already accepted body and response" {
    var stop: std.Io.Event = .unset;
    var options = config();
    options.connection_budget = null;
    options.stop = &stop;
    const result = try exchange(null, options, "POST /echo HTTP/1.1\r\ncontent-length: 5\r\nexpect: 100-continue\r\n\r\n", "hello");
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nhello"));
}

test "ingress limits and unsupported sessions close without invoking handler" {
    var options = config();
    options.target_bytes = 4;
    options.header_count = 1;
    inline for (.{
        "GET /excess HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nx: 1\r\ny: 2\r\n\r\n",
        "GET / HTTP/1.1\r\nupgrade: websocket\r\n\r\n",
        "GET / HTTP/1.1\r\nexpect: unsupported\r\n\r\n",
        "POST / HTTP/1.1\r\ncontent-length: 0\r\ntransfer-encoding: chunked\r\n\r\n",
        "not http\r\n\r\n",
    }) |wire| {
        const result = try exchange(null, options, wire, null);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }
    options.head_bytes = 24;
    const result = try exchange(null, options, "GET / HTTP/1.1\r\nlong: value\r\n\r\n", null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

fn invalidResponse(request: Request) Response {
    return request.response(.{ .headers = &.{.{ .name = "content-length", .value = "100" }} });
}

test "invalid responses fail before writing and close the pending socket" {
    try std.testing.expectError(error.InvalidHttpResponse, exchange(invalidResponse, config(), "GET / HTTP/1.1\r\n\r\n", null));
    var options = config();
    options.response_body_bytes = 1;
    try std.testing.expectError(error.InvalidHttpResponse, exchange(null, options, "GET /health HTTP/1.1\r\n\r\n", null));
}

test "body timeout cannot be converted into a successful handler response" {
    var options = config();
    options.request_timeout = .fromMilliseconds(50);
    try std.testing.expectError(error.Timeout, exchange(null, options, "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\n", null));
}

test "truncated fixed-length and malformed chunked bodies reach application policy" {
    const truncated = try exchangePeer(null, config(), "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\nabc", null, true);
    defer allocator.free(truncated);
    try expectContains(truncated, "400 Bad Request\r\n");
    const malformed = try exchange(null, config(), "POST /echo HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n2\r\nabxx", null);
    defer allocator.free(malformed);
    try expectContains(malformed, "400 Bad Request\r\n");
}

fn sendSingle(response: Response) !void {
    try run(.{ allocator, io }, .{pipe(zrx.fromValue(response), .{respondHttp()})});
}

fn sendArray(response: Response) !void {
    const values = [_]Response{response};
    try run(.{ allocator, io }, .{pipe(zrx.fromSlice(&values), .{respondHttp()})});
}

test "explicit effect and scalar or borrowed-array terminals use the same send rule" {
    inline for (.{ sendHttpResponse, sendSingle, sendArray }) |effect| {
        const Application = struct {
            pub const handle = echo.healthResponse;
            pub const terminal = forEach(effect);
        };
        const result = try exchange(Application, config(), "GET /health HTTP/1.1\r\n\r\n", null);
        defer allocator.free(result);
        try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nok\n"));
    }
}

fn sendTwice(response: Response) !void {
    try sendHttpResponse(response);
    try sendHttpResponse(response);
}

test "a duplicate response fails without a second protocol write" {
    const Application = struct {
        pub const handle = echo.healthResponse;
        pub const terminal = forEach(sendTwice);
    };
    try std.testing.expectError(error.InvalidHttpResponse, exchange(Application, config(), "GET /health HTTP/1.1\r\n\r\n", null));
}

fn ignoreResponse(_: Response) void {}

test "terminal completion without response safely closes the request" {
    const Application = struct {
        pub const handle = echo.healthResponse;
        pub const terminal = forEach(ignoreResponse);
    };
    var options = config();
    options.request_timeout = .fromMilliseconds(50);
    const result = try exchange(Application, options, "GET /health HTTP/1.1\r\n\r\n", null);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

fn never(_: Request) bool {
    return false;
}
fn ignoreRequest(_: Request) void {}

test "HTTP unmatched and filtered branch items finalize without a response" {
    const Unmatched = struct {
        pub const handle = echo.healthResponse;
        pub const operator = branch(.{when(never, each(echo.healthResponse))});
        pub const terminal = respondHttp();
    };
    const Filtered = struct {
        pub const handle = echo.healthResponse;
        pub const operator = branch(.{otherwise(.{ filter(never), each(echo.healthResponse) })});
        pub const terminal = respondHttp();
    };
    inline for (.{ Unmatched, Filtered }) |Application| {
        const result = try exchange(Application, config(), "GET /health HTTP/1.1\r\n\r\n", null);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }
}

test "all-terminating HTTP cases send or safely close through one branch flow" {
    const Application = struct {
        pub const handle = echo.healthResponse;
        pub const operator = branch(.{
            when(never, forEach(ignoreRequest)),
            otherwise(.{ each(echo.healthResponse), respondHttp() }),
        });
        // The outer pipeline has already terminated.
    };
    const result = try exchange(Application, config(), "GET /health HTTP/1.1\r\n\r\n", null);
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\nok\n"));
}

fn allocationFixture(a: std.mem.Allocator) !void {
    var options = config();
    options.connection_budget = 0;
    try echo.execute(a, io, options);
}

test "every allocation failure releases partial graph and HTTP storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFixture, .{});
}

test "listen failure releases prepared buffers without signaling ready" {
    var listener = try config().address.listen(io, .{});
    defer listener.deinit(io);
    var ready: zrx.HttpReady = .{};
    var options = config();
    options.address = listener.socket.address;
    options.ready = &ready;
    try std.testing.expectError(error.AddressInUse, echo.execute(allocator, io, options));
    try std.testing.expect(!ready.ready.isSet());
}

test "worker startup failure never acquires the HTTP listener" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var ready: zrx.HttpReady = .{};
    var options = config();
    options.ready = &ready;
    const incoming = httpRequests(options);
    const replies = pipe(&incoming, .{each(echo.healthResponse)});
    const empty: []const Response = &.{};
    try std.testing.expectError(error.ConcurrencyUnavailable, run(.{ allocator, backend.io() }, .{
        pipe(&replies, .{respondHttp()}),
        pipe(zrx.fromSlice(empty), .{forEach(ignoreResponse)}),
    }));
    try std.testing.expect(!ready.ready.isSet());
}

const ExampleRun = struct {
    options: zrx.HttpServerConfig,
    done: std.Io.Event = .unset,
    fn execute(self: *@This()) !void {
        defer self.done.set(io);
        try echo.execute(allocator, io, self.options);
    }
};

test "idle accept responds to graceful stop and parent cancellation" {
    inline for (.{ false, true }) |cancel| {
        var ready: zrx.HttpReady = .{};
        var stop: std.Io.Event = .unset;
        var server: ExampleRun = .{ .options = config() };
        server.options.ready = &ready;
        server.options.stop = if (cancel) null else &stop;
        var task = try io.concurrent(ExampleRun.execute, .{&server});
        defer task.cancel(io) catch {};
        try ready.ready.waitTimeout(io, watchdog);
        if (cancel) {
            try std.testing.expectError(error.Canceled, task.cancel(io));
        } else {
            stop.set(io);
            try server.done.waitTimeout(io, watchdog);
            try task.await(io);
        }
        // Owned listening handle is gone after joining.
        var rebound = try ready.address.listen(io, .{});
        rebound.deinit(io);
    }
}

test "serial connections reuse bounded storage without mixing associated responses" {
    var ready: zrx.HttpReady = .{};
    var server: ExampleRun = .{ .options = config() };
    server.options.ready = &ready;
    server.options.connection_budget = 3;
    var task = try io.concurrent(ExampleRun.execute, .{&server});
    defer task.cancel(io) catch {};
    try ready.ready.waitTimeout(io, watchdog);
    const Peer = struct {
        address: std.Io.net.IpAddress,
        wire: []const u8,
        output: [1024]u8 = undefined,
        len: usize = 0,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            const connection = try self.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer connection.close(io);
            var write_buffer: [128]u8 = undefined;
            var writer = connection.writer(io, &write_buffer);
            // Deliberately fragment the head, independently of TCP packetization.
            for (self.wire) |byte| {
                try writer.interface.writeByte(byte);
                try writer.interface.flush();
            }
            var read_buffer: [1024]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            self.len = try reader.interface.readSliceShort(&self.output);
        }
    };
    inline for (.{ "first", "other", "third" }) |text| {
        var peer: Peer = .{
            .address = ready.address,
            .wire = "POST /echo HTTP/1.1\r\ncontent-length: 5\r\n\r\n" ++ text,
        };
        var client = try io.concurrent(Peer.execute, .{&peer});
        defer client.cancel(io) catch {};
        try peer.done.waitTimeout(io, watchdog);
        try client.await(io);
        try std.testing.expect(std.mem.endsWith(u8, peer.output[0..peer.len], "\r\n\r\n" ++ text));
    }
    try server.done.waitTimeout(io, watchdog);
    try task.await(io);
}

test "cancel during on-demand body read joins users and sends no fallback response" {
    var ready: zrx.HttpReady = .{};
    var server: ExampleRun = .{ .options = config() };
    server.options.ready = &ready;
    var task = try io.concurrent(ExampleRun.execute, .{&server});
    defer task.cancel(io) catch {};
    try ready.ready.waitTimeout(io, watchdog);
    const Peer = struct {
        address: std.Io.net.IpAddress,
        continued: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            const connection = try self.address.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer connection.close(io);
            var buffer: [128]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("POST /echo HTTP/1.1\r\ncontent-length: 5\r\nexpect: 100-continue\r\n\r\n");
            try writer.interface.flush();
            var reader = connection.reader(io, &buffer);
            var continuation: ["HTTP/1.1 100 Continue\r\n\r\n".len]u8 = undefined;
            try reader.interface.readSliceAll(&continuation);
            try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", &continuation);
            self.continued.set(io);
            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
        }
    };
    var peer: Peer = .{ .address = ready.address };
    var client = try io.concurrent(Peer.execute, .{&peer});
    defer client.cancel(io) catch {};
    try peer.continued.waitTimeout(io, watchdog);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try peer.done.waitTimeout(io, watchdog);
    try client.await(io);
}
