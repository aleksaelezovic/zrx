//! Bounded, serial HTTP/1.x servers. Declarations are cold; run owns transport.
const std = @import("std");
const builtin = @import("builtin");
const sequences = @import("../data/sequences.zig");
const streams = @import("../internal/runtime/streams.zig");
const runtime = @import("../internal/runtime/http.zig");
const resources = @import("../internal/resources.zig");
const execution = @import("../internal/graph_run.zig");

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

    /// Detailed cause after a body reader's ReadFailed.
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
};

pub const HttpResponseOptions = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
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

/// Declare a cold HTTP request stream. run prepares storage/workers, listens,
/// then accepts serially. Exclusive branch, each, filter, take, and per-item
/// terminals track delivery completion. Dropped/unanswered requests close after
/// their last delivery; answered requests are never sent twice. Independent
/// fan-out, retention, batching, collection, and signal dependencies unsupported.
/// Parse/peer head failures close that session; runtime/terminal errors fail run.
pub fn httpRequests(config: HttpServerConfig) Source {
    if (builtin.os.tag == .freestanding) @compileError("HTTP requires a hosted target");
    return .{ .config = config };
}

const Source = struct {
    pub const sequence_tag = sequences.SequenceTag;
    pub const graph_tag = sequences.GraphTag;
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
    return T == Source;
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
