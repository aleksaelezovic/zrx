//! Bounded, serial HTTP/1.x servers. Declarations are cold; run owns transport.
const std = @import("std");
const builtin = @import("builtin");
const sequences = @import("../data/sequences.zig");
const streams = @import("../internal/runtime/streams.zig");
const runtime = @import("../internal/runtime/http.zig");
const resources = @import("../internal/resources.zig");
const execution = @import("../internal/graph_run.zig");
const Configured = @import("../internal/world/configured.zig").Configured;
const configured = @import("../internal/world/configured.zig").configured;
const completion = @import("../internal/runtime/completion.zig");
const SourceTag = opaque {};

/// Stable protocol/body-limit failures. Transport, timeout and cancellation
/// errors remain distinct control failures, not members of this subset.
pub const HttpBodyError = error{ HttpBodyTooLarge, HttpInvalidBody };

/// Optional borrowed readiness capability. Use once per run; wait on ready
/// before reading address. Acquisition failure does not signal readiness.
pub const HttpReady = struct {
    ready: std.Io.Event = .unset,
    address: std.Io.net.IpAddress = undefined,
};

/// Configuration, not an open listener. Bounds are per server, not type
/// parameters. One active connection/request; every response closes it.
/// stop stops admission and drains the accepted session within request_timeout.
/// connection_budget counts accepted sockets, including rejected/empty sessions.
/// ready/stop referents must outlive run; do not reuse readiness concurrently.
pub const HttpServerConfig = struct {
    address: std.Io.net.IpAddress,
    listen: std.Io.net.IpAddress.ListenOptions = .{},
    head_bytes: usize = 8192,
    target_bytes: usize = 1024,
    header_count: usize = 32,
    request_body_bytes: usize = 65536,
    response_body_bytes: usize = 65536,
    response_header_bytes: usize = 8192,
    response_header_count: usize = 32,
    head_timeout: std.Io.Duration = .fromSeconds(5),
    request_timeout: std.Io.Duration = .fromSeconds(30),
    connection_budget: ?usize = null,
    ready: ?*HttpReady = null,
    stop: ?*std.Io.Event = null,
};

/// Stable resource-owned server. Do not move/copy after acquisition. One request
/// traversal per acquisition; borrowed owners must release/reacquire before
/// another run. Request sources interrupt/join users but do not release this
/// owner. Distinct service aliases cannot serve the same owner concurrently.
pub const HttpServer = struct {
    _state: runtime.Server,
    _claimed: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, config: HttpServerConfig) HttpServer {
        return .{ ._state = .{ .allocator = allocator, .config = config } };
    }
    pub fn acquire(self: *HttpServer, io: std.Io) !void {
        const config = self._state.config;
        const allocator = self._state.allocator;
        self._state = .{ .config = config, .allocator = allocator };
        try runtime.validate(config);
        try self._state.acquire(io);
    }
    pub fn address(self: *const HttpServer) std.Io.net.IpAddress {
        return self._state.listener.socket.address;
    }
    pub fn release(self: *HttpServer, io: std.Io) void {
        std.debug.assert(!self._claimed.load(.acquire));
        self._state.release(io);
    }
};

/// Cold recipe providing *HttpServer. Configuration values and typed injected
/// Config/E!Config providers follow the same rules as reader/writer. To add
/// acquisition behavior, use a dependent custom resource/nominal wrapper.
pub fn httpServer(config: anytype) Configured(HttpServerConfig, if (@typeInfo(@TypeOf(config)) == .@"fn") config else {}, openServer, closeServer) {
    if (builtin.os.tag == .freestanding) @compileError("HTTP requires a hosted target");
    return configured(HttpServerConfig, config, openServer, closeServer);
}

fn openServer(allocator: std.mem.Allocator, io: std.Io, config: HttpServerConfig) !*HttpServer {
    const server = try allocator.create(HttpServer);
    errdefer allocator.destroy(server);
    server.* = HttpServer.init(allocator, config);
    try server.acquire(io);
    return server;
}

fn closeServer(allocator: std.mem.Allocator, io: std.Io, server: *HttpServer) void {
    server.release(io);
    allocator.destroy(server);
}

/// Run-scoped request capability. Copies share one body cursor. All exposed
/// slices and readers are borrowed until this request's last delivery completes;
/// do not retain them or fan out requests into independently running branches.
/// Cancellation is recorded by the runtime even if a handler catches ReadFailed.
pub const HttpRequest = struct {
    method: std.http.Method,
    target: []const u8,
    headers: []const std.http.Header,
    version: std.http.Version,
    _server: *runtime.Server,
    _generation: usize,

    pub const HeaderValues = struct {
        headers: []const std.http.Header,
        name: []const u8,
        index: usize = 0,

        pub fn next(self: *HeaderValues) ?[]const u8 {
            while (self.index < self.headers.len) {
                const header = self.headers[self.index];
                self.index += 1;
                if (std.ascii.eqlIgnoreCase(header.name, self.name)) return header.value;
            }
            return null;
        }
    };

    /// Case-insensitive lookup preserving every occurrence in wire order.
    /// Values and the iterator's name remain borrowed; no allocation or lifetime
    /// extension. Keep name alive through iteration and values within the request.
    pub fn headerValues(self: HttpRequest, name: []const u8) HeaderValues {
        return .{ .headers = self.headers, .name = name };
    }

    /// Missing is null. Repeated headers fail even when their values are equal;
    /// the caller, not this adapter, chooses the rejection/status policy.
    pub fn uniqueHeader(self: HttpRequest, name: []const u8) error{DuplicateHttpHeader}!?[]const u8 {
        var values = self.headerValues(name);
        const first = values.next() orelse return null;
        if (values.next() != null) return error.DuplicateHttpHeader;
        return first;
    }

    /// Lazily expose a standard HTTP-framed reader. Body limits apply across
    /// byte, slice, stream, and discard operations. Concurrent reads unsupported.
    /// Reader errors use ReadFailed; bodyError() supplies the underlying cause.
    /// 100 Continue is sent only on demand. No decompression or replay.
    pub fn bodyReader(self: HttpRequest) !*std.Io.Reader {
        return self._server.bodyReader(self._generation);
    }

    /// Consume the shared cursor's remainder into request-owned storage. With
    /// no prior reads this is the whole body. Repeated calls do not replay.
    pub fn readRemainingBody(self: HttpRequest) ![]const u8 {
        const reader = try self.bodyReader();
        const storage = self._server.body_storage;
        const n = reader.readSliceShort(storage) catch return self.bodyError() orelse error.ReadFailed;
        if (n == storage.len) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return storage[0..n],
                error.ReadFailed => return self.bodyError() orelse err,
            };
            return error.HttpBodyTooLarge;
        }
        return storage[0..n];
    }

    /// Cause after a body reader's ReadFailed. Known malformed/truncated framing
    /// is normalized to HttpInvalidBody; limits use HttpBodyTooLarge. Other
    /// I/O, timeout and cancellation causes are preserved.
    pub fn bodyError(self: HttpRequest) ?anyerror {
        return self._server.bodyFailure(self._generation);
    }

    /// Construct, never send. Copies bytes into bounded request-owned storage.
    /// Construct once per request; copies of Response share that storage.
    /// Invalid/over-bound options produce a Response rejected by the terminal,
    /// not a hidden 500 or a discarded error. Handler error policy is caller-owned.
    pub fn response(self: HttpRequest, options: HttpResponseOptions) HttpResponse {
        return self._server.response(self._generation, options);
    }

    /// Encode with std.json into the bounded response buffer, without allocation
    /// or sending. Adds application/json; options.headers must not include
    /// content-type or adapter-owned framing headers. Policy remains caller-owned.
    ///
    /// Like response(), this claims the request's one construction attempt.
    /// Failure returns no token and permits neither another construction nor an
    /// implicit fallback. No user jsonStringify callback runs under the mutex.
    /// Excess output returns HttpResponseTooLarge; invalid options/token return
    /// InvalidHttpResponse. Referents need only survive this encoding call.
    pub fn jsonResponse(self: HttpRequest, value: anytype, options: HttpJsonResponseOptions) !HttpResponse {
        return self._server.jsonResponse(self._generation, value, options);
    }
};

pub const HttpResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
};

pub const HttpJsonResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    /// JSON itself has no implicit record delimiter.
    newline: bool = false,
};

/// Associated, borrowed response, valid only in the originating run/request.
/// No automatic recovery. Status/headers/body are immutable transport payload.
pub const HttpResponse = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
    _server: *runtime.Server,
    _generation: usize,
    _invalid: bool = false,
};

/// Cold typed method predicate, suitable for when/filter/all/any.
pub fn httpMethod(comptime method: std.http.Method) fn (HttpRequest) bool {
    return struct {
        fn matches(request: HttpRequest) bool {
            return request.method == method;
        }
    }.matches;
}

/// Match the entire raw request-target, including query bytes; no decoding,
/// normalization or wildcard interpretation.
pub fn httpTarget(comptime target: []const u8) fn (HttpRequest) bool {
    return targetPredicate(.exact, false, target);
}
pub fn httpTargetPrefix(comptime prefix: []const u8) fn (HttpRequest) bool {
    return targetPredicate(.prefix, false, prefix);
}

/// Match an origin-form raw path, ignoring a query suffix. Non-origin targets
/// do not match. Percent escapes remain bytes; no path canonicalization.
pub fn httpPath(comptime path: []const u8) fn (HttpRequest) bool {
    return targetPredicate(.exact, true, path);
}
/// Literal byte prefix, not a segment matcher: use "/jobs/" for descendants.
pub fn httpPathPrefix(comptime prefix: []const u8) fn (HttpRequest) bool {
    return targetPredicate(.prefix, true, prefix);
}

const TargetMatch = enum { exact, prefix };
fn targetPredicate(comptime mode: TargetMatch, comptime path_only: bool, comptime expected: []const u8) fn (HttpRequest) bool {
    return struct {
        fn matches(request: HttpRequest) bool {
            var target = request.target;
            if (path_only) {
                if (target.len == 0 or target[0] != '/') return false;
                target = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
            }
            return switch (mode) {
                .exact => std.mem.eql(u8, target, expected),
                .prefix => std.mem.startsWith(u8, target, expected),
            };
        }
    }.matches;
}

/// Declare a cold HTTP request stream. run prepares storage/workers, listens,
/// then accepts serially. Exclusive branch, each, filter, take, and per-item
/// terminals track delivery completion. Dropped/unanswered requests close after
/// their last delivery; answered requests are never sent twice. Independent
/// fan-out, retention, batching, collection, and signal dependencies unsupported.
/// Parse/peer head failures close that session; runtime/terminal errors fail run.
/// Supply concrete configuration or an exact server service TYPE: *HttpServer
/// or a single-field nominal wrapper containing *HttpServer. The service form
/// borrows an acquired owner. Runtime role aliases fail HttpServerInUse before
/// source activation; repeated use of the same service rejects fan-out cold.
/// For contextual member syntax such as .loopback, use a typed configuration
/// literal: httpRequests(HttpServerConfig{ ... }).
pub fn httpRequests(config: anytype) HttpSource(@TypeOf(config), if (@TypeOf(config) == type) config else void) {
    if (builtin.os.tag == .freestanding) @compileError("HTTP requires a hosted target");
    if (comptime @TypeOf(config) == type) return .{};
    return .{ .config = config };
}

fn HttpSource(comptime Config: type, comptime Service: type) type {
    if (Config != type) return Source;
    if (Service != *HttpServer) {
        if (@typeInfo(Service) != .@"struct" or @typeInfo(Service).@"struct".is_tuple or
            @typeInfo(Service).@"struct".field_types.len != 1 or
            @typeInfo(Service).@"struct".field_types[0] != *HttpServer)
            @compileError("httpRequests: expected *HttpServer service or a single-field nominal wrapper");
    }
    return struct {
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const http_source_tag = SourceTag;
        pub const server_service = Service;
        pub const Requirements = [_]type{Service};
        pub const Item = HttpRequest;
        capacity: usize = 1,
    };
}

const Source = struct {
    pub const sequence_tag = sequences.SequenceTag;
    pub const graph_tag = sequences.GraphTag;
    pub const http_source_tag = SourceTag;
    pub const Item = HttpRequest;
    config: HttpServerConfig,
    capacity: usize = 1,

    pub fn instantiate(self: Source, scope: *resources.Scope) !streams.Stream(Item) {
        try runtime.validate(self.config);
        const slot = try scope.add(runtime.Server, .{
            .config = self.config,
            .allocator = scope.allocator,
        }, null);
        var stream = try streams.Stream(Item).initProducer(scope.allocator, scope.io, 1, runtime.Server.produce, slot);
        stream.setCompletion(slot.completionOwner());
        return stream;
    }
};

pub fn isSource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "http_source_tag") and T.http_source_tag == SourceTag;
}

pub fn isConfigured(comptime T: type) bool {
    return isSource(T) and @hasDecl(T, "server_service");
}

/// Private service binding bridge. The request lane only borrows its server;
/// typed resources release it after the graph stops/joins all request users.
pub fn Bound(comptime Definition: type, comptime Env: type) type {
    return struct {
        pub const sequence_tag = sequences.SequenceTag;
        pub const graph_tag = sequences.GraphTag;
        pub const http_source_tag = SourceTag;
        pub const http_service_source = true;
        pub const Item = HttpRequest;
        capacity: usize,
        env: *Env,

        const Owner = struct {
            server: ?*HttpServer = null,
            env: *Env,

            pub fn acquire(self: *@This(), _: std.Io) !void {
                const value = self.env.get(Definition.server_service);
                const server = if (@TypeOf(value) == *HttpServer)
                    value
                else
                    @field(value, @typeInfo(@TypeOf(value)).@"struct".field_names[0]);
                if (server._claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
                    return error.HttpServerInUse;
                self.server = server;
            }
            pub fn interrupt(self: *@This(), io: std.Io) void {
                if (self.server) |server| server._state.interrupt(io);
            }
            pub fn release(self: *@This(), _: std.Io) void {
                self.server.?._claimed.store(false, .release);
            }
            fn produce(self: *@This(), output: *streams.Stream(Item)) !void {
                try self.server.?._state.produce(output);
            }
        };

        pub fn instantiate(self: @This(), scope: *resources.Scope) !streams.Stream(Item) {
            const slot = try scope.add(Owner, .{ .env = self.env }, null);
            var stream = try streams.Stream(Item).initProducer(scope.allocator, scope.io, 1, Owner.produce, slot);
            stream.setCompletion(.{
                .context = slot,
                .acquire_fn = acquireDelivery,
                .peek_fn = peekDelivery,
                .abort_fn = abortDelivery,
            });
            return stream;
        }

        fn acquireDelivery(context: *anyopaque) std.Io.Cancelable!completion.Token {
            const owner: *Owner = @ptrCast(@alignCast(context));
            return owner.server.?._state.completionOwner().acquire();
        }
        fn peekDelivery(context: *anyopaque) completion.Token {
            const owner: *Owner = @ptrCast(@alignCast(context));
            return owner.server.?._state.completionOwner().peek();
        }
        fn abortDelivery(context: *anyopaque) void {
            const owner: *Owner = @ptrCast(@alignCast(context));
            if (owner.server) |server| server._state.completionOwner().abort();
        }
    };
}

/// Explicit per-response effect, also usable with forEach. Flushes before
/// completing the send; request credit waits for all deliveries to finish.
/// Never retries partial writes. One send per token.
pub fn sendHttpResponse(response: HttpResponse) !void {
    try response._server.send(response);
}

/// Deferred no-output terminal for Response, borrowed response arrays/slices,
/// or response streams. Reject error unions; handlers must produce Response.
pub fn respondHttp() Sink {
    return .{};
}

const Single = struct {
    pub const sequence_tag = sequences.SequenceTag;
    pub const Item = HttpResponse;
    value: HttpResponse,
    pub const Iterator = struct {
        value: ?HttpResponse,
        pub fn next(self: *@This()) ?HttpResponse {
            const value = self.value;
            self.value = null;
            return value;
        }
    };
    pub fn iterator(self: Single) Iterator {
        return .{ .value = self.value };
    }
};

const Sink = struct {
    fn Input(comptime T: type) type {
        return if (T == HttpResponse) Single else T;
    }
    pub fn Output(comptime T: type) type {
        if (sequences.Item(Input(T)) != HttpResponse)
            @compileError("respondHttp: expected HttpResponse values, not error unions or other items");
        return execution.Flow(Input(T), Consumer);
    }
    pub fn apply(_: Sink, source: anytype) Output(@TypeOf(source)) {
        return .{ .source = if (@TypeOf(source) == HttpResponse) .{ .value = source } else source, .consumer = .{} };
    }
};

const Consumer = struct {
    pub fn prepare(_: *Consumer, _: std.mem.Allocator) !void {}
    pub fn deinit(_: *Consumer, _: std.mem.Allocator) void {}
    pub fn consume(_: Consumer, reader: anytype, _: std.mem.Allocator, io: std.Io) !void {
        var input = reader.iterator();
        while (true) {
            try io.checkCancel();
            try sendHttpResponse((try input.next()) orelse return);
        }
    }
};
