//! Serial HTTP session machinery. No user callbacks or socket waits under locks.
const std = @import("std");
const api = @import("../../io/http.zig");
const streams = @import("streams.zig");
const completion = @import("completion.zig");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub fn validate(c: api.HttpServerConfig) !void {
    if (c.head_bytes < 16 or c.target_bytes == 0 or
        c.head_timeout.nanoseconds <= 0 or c.request_timeout.nanoseconds <= 0 or
        c.listen.mode != .stream or c.listen.protocol != .tcp)
        return error.InvalidHttpConfig;
}

pub const Server = struct {
    config: api.HttpServerConfig,
    allocator: std.mem.Allocator,
    io: std.Io = undefined,
    listener: std.Io.net.Server = undefined,
    connection: ?std.Io.net.Stream = null,
    generation: usize = 0,
    pending: bool = false,
    sent: bool = false,
    built: bool = false,
    deliveries: usize = 0,
    mutex: std.Io.Mutex = .init,
    interrupted: bool = false,
    done: std.Io.Event = .unset,
    deadline: std.Io.Clock.Timestamp = undefined,
    input: Input = undefined,
    output: Output = undefined,
    http: std.http.Server = undefined,
    request: std.http.Server.Request = undefined,
    body: Body = undefined,
    body_started: bool = false,
    body_storage: []u8 = &.{},
    head_storage: []u8 = &.{},
    head_copy: []u8 = &.{},
    headers: []std.http.Header = &.{},
    response_body: []u8 = &.{},
    response_headers: []std.http.Header = &.{},
    response_text: []u8 = &.{},
    response_options: api.HttpResponseOptions = .{},
    write_buffer: [4096]u8 = undefined,
    transfer_buffer: [4096]u8 = undefined,
    body_buffer: [4096]u8 = undefined,

    pub fn acquire(self: *Server, io: std.Io) !void {
        self.io = io;
        const a = self.allocator;
        self.head_storage = try a.alloc(u8, self.config.head_bytes);
        errdefer a.free(self.head_storage);
        self.head_copy = try a.alloc(u8, self.config.head_bytes);
        errdefer a.free(self.head_copy);
        self.headers = try a.alloc(std.http.Header, self.config.header_count);
        errdefer a.free(self.headers);
        self.body_storage = try a.alloc(u8, self.config.request_body_bytes);
        errdefer a.free(self.body_storage);
        self.response_body = try a.alloc(u8, self.config.response_body_bytes);
        errdefer a.free(self.response_body);
        self.response_headers = try a.alloc(std.http.Header, self.config.response_header_count);
        errdefer a.free(self.response_headers);
        self.response_text = try a.alloc(u8, self.config.response_header_bytes);
        errdefer a.free(self.response_text);
        self.listener = try self.config.address.listen(io, self.config.listen);
        if (self.config.ready) |ready| {
            ready.address = self.listener.socket.address;
            ready.ready.set(io);
        }
    }

    // run releases only after all graph/terminal tasks have joined. In particular,
    // a canceled producer cannot free buffers still used by a canceled handler.
    pub fn release(self: *Server, io: std.Io) void {
        self.closeConnection();
        self.listener.deinit(io);
        const a = self.allocator;
        a.free(self.response_text);
        a.free(self.response_headers);
        a.free(self.response_body);
        a.free(self.body_storage);
        a.free(self.headers);
        a.free(self.head_copy);
        a.free(self.head_storage);
    }

    // Shutdown, not close: pending syscalls must stop before graph joins, but
    // handles/buffers cannot be released until their users have joined.
    pub fn interrupt(self: *Server, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.interrupted = true;
        if (self.connection) |connection| connection.shutdown(io, .both) catch {};
    }

    fn closeConnection(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.connection) |connection| connection.close(self.io);
        self.connection = null;
    }

    pub fn produce(self: *Server, output: *streams.Stream(api.HttpRequest)) !void {
        var count: usize = 0;
        while (self.config.connection_budget == null or count < self.config.connection_budget.?) {
            try self.io.checkCancel();
            const connection = (try self.accept()) orelse return;
            self.mutex.lockUncancelable(self.io);
            if (self.interrupted) {
                self.mutex.unlock(self.io);
                connection.close(self.io);
                return error.Canceled;
            }
            self.connection = connection;
            self.generation = std.math.add(usize, self.generation, 1) catch {
                self.mutex.unlock(self.io);
                return error.HttpSequenceOverflow;
            };
            count = self.generation;
            self.pending = false;
            self.sent = false;
            self.built = false;
            self.body_started = false;
            self.mutex.unlock(self.io);
            self.done.reset();
            self.deadline = .fromNow(self.io, .{ .raw = self.config.request_timeout, .clock = .awake });
            const head_deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = self.config.head_timeout, .clock = .awake });
            self.input = .{
                .server = self,
                .timeout = .{ .deadline = if (head_deadline.raw.compare(.lt, self.deadline.raw)) head_deadline else self.deadline },
                .interface = .{ .vtable = &.{ .stream = Input.read }, .buffer = self.head_storage, .seek = 0, .end = 0 },
            };
            self.output = .{
                .server = self,
                .interface = .{ .vtable = &.{ .drain = Output.write }, .buffer = &self.write_buffer },
            };
            self.http = .init(&self.input.interface, &self.output.interface);
            self.request = self.http.receiveHead() catch {
                if (self.input.err) |cause| {
                    if (cause == error.Canceled or cause == error.ConcurrencyUnavailable) return cause;
                }
                self.closeConnection();
                continue;
            };
            const value = self.snapshot() catch {
                self.closeConnection();
                continue;
            };
            self.input.timeout = .{ .deadline = self.deadline };
            self.mutex.lockUncancelable(self.io);
            self.pending = true;
            self.deliveries = 1;
            self.mutex.unlock(self.io);
            output.push(value) catch |err| {
                self.releaseDelivery(self.generation);
                return err;
            };
            self.releaseDelivery(self.generation);
            // Per-item completion, never EOF, releases the one request credit.
            while (true) {
                self.done.waitTimeout(self.io, .{ .deadline = self.deadline }) catch |err| {
                    if (err == error.Timeout and self.deadline.untilNow(self.io).raw.nanoseconds < 0) continue;
                    return err;
                };
                break;
            }
            self.mutex.lockUncancelable(self.io);
            self.pending = false;
            self.mutex.unlock(self.io);
            self.closeConnection();
        }
    }

    fn accept(self: *Server) !?std.Io.net.Stream {
        const stop = self.config.stop orelse return try self.listener.accept(self.io);
        if (stop.isSet()) return null;
        const Result = union(enum) { accepted: anyerror!std.Io.net.Stream, stopped: std.Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select: std.Io.Select(Result) = .init(self.io, &buffer);
        // Even a losing accept may return a socket; join and close all losers.
        defer while (select.cancel()) |result| {
            if (result == .accepted) {
                if (result.accepted) |connection| connection.close(self.io) else |_| {}
            }
        };
        try select.concurrent(.accepted, std.Io.net.Server.accept, .{ &self.listener, self.io });
        try select.concurrent(.stopped, std.Io.Event.wait, .{ stop, self.io });
        return switch (try select.await()) {
            .accepted => |result| try result,
            .stopped => |result| blk: {
                try result;
                break :blk null;
            },
        };
    }

    fn snapshot(self: *Server) !api.HttpRequest {
        const head = self.request.head;
        if (head.target.len > self.config.target_bytes or head.method == .CONNECT or
            head.transfer_compression != .identity or
            (head.transfer_encoding != .none and head.content_length != null))
            return error.UnsupportedHttpRequest;
        if (head.expect) |expect| {
            if (!std.mem.eql(u8, expect, "100-continue")) return error.UnsupportedHttpRequest;
        }
        const bytes = self.request.head_buffer;
        @memcpy(self.head_copy[0..bytes.len], bytes);
        const target_offset = @intFromPtr(head.target.ptr) - @intFromPtr(bytes.ptr);
        var iterator = std.http.HeaderIterator.init(self.head_copy[0..bytes.len]);
        var count: usize = 0;
        while (iterator.next()) |header| {
            if (count == self.headers.len or !validHeader(header)) return error.InvalidHttpHeaders;
            if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) return error.UnsupportedHttpRequest;
            self.headers[count] = header;
            count += 1;
        }
        return .{
            .method = head.method,
            .target = self.head_copy[target_offset..][0..head.target.len],
            .headers = self.headers[0..count],
            .version = head.version,
            ._server = self,
            ._generation = self.generation,
        };
    }

    pub fn bodyReader(self: *Server, generation: usize) !*Reader {
        if (!self.pending or generation != self.generation or self.sent) return error.InvalidHttpRequest;
        self.io.checkCancel() catch |err| {
            self.input.err = err;
            return err;
        };
        if (!self.body_started) {
            self.body = .{ .server = self, .interface = .{
                .vtable = &.{ .stream = Body.read },
                .buffer = &self.body_buffer,
                .seek = 0,
                .end = 0,
            } };
            self.body_started = true;
            if ((self.request.head.content_length orelse 0) > self.config.request_body_bytes)
                self.body.err = error.HttpBodyTooLarge;
            if (self.body.err) |err| return err;
            // Framing is independent of method. In particular, do not wait for
            // socket EOF when no Content-Length or Transfer-Encoding was sent.
            self.request.writeExpectContinue() catch return self.output.err orelse error.WriteFailed;
            try self.output.interface.flush();
            const head = self.request.head;
            self.body.input = self.http.reader.bodyReader(&self.transfer_buffer, head.transfer_encoding, head.content_length orelse
                (if (head.transfer_encoding == .none) @as(u64, 0) else null));
        }
        if (self.body.err) |err| return err;
        return &self.body.interface;
    }

    pub fn bodyFailure(self: *Server, generation: usize) ?anyerror {
        if (generation != self.generation) return error.InvalidHttpRequest;
        if (!self.body_started) return null;
        return self.body.err;
    }

    fn beginResponse(self: *Server, generation: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.pending or generation != self.generation or self.sent or self.built)
            return false;
        self.built = true;
        return true;
    }

    pub fn response(self: *Server, generation: usize, options: api.HttpResponseOptions) api.HttpResponse {
        if (!self.beginResponse(generation))
            return .{ ._server = self, ._generation = generation, ._invalid = true };
        self.copyResponse(options) catch return .{ ._server = self, ._generation = generation, ._invalid = true };
        return self.responseValue(generation);
    }

    pub fn jsonResponse(self: *Server, generation: usize, value: anytype, options: api.HttpJsonResponseOptions) !api.HttpResponse {
        if (!self.beginResponse(generation)) return error.InvalidHttpResponse;
        const content_type: std.http.Header = .{ .name = "content-type", .value = "application/json" };
        if (options.status == .no_content or options.status == .not_modified) return error.InvalidHttpResponse;
        for (options.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) return error.InvalidHttpResponse;
        }
        try self.validateResponse(.{ .status = options.status, .headers = options.headers }, content_type);
        // The request's exclusive delivery keeps storage alive through callbacks.
        // Claim construction under the mutex, then encode OUTSIDE it.
        var output: JsonWriter = .{ .interface = .fixed(self.response_body) };
        output.interface.vtable = &JsonWriter.vtable;
        std.json.Stringify.value(value, .{}, &output.interface) catch |err|
            return if (output.exceeded) error.HttpResponseTooLarge else err;
        if (options.newline) output.interface.writeByte('\n') catch return error.HttpResponseTooLarge;
        var offset: usize = 0;
        try self.copyHeader(content_type, 0, &offset);
        for (options.headers, 1..) |header, i| try self.copyHeader(header, i, &offset);
        self.response_options = .{
            .status = options.status,
            .headers = self.response_headers[0 .. options.headers.len + 1],
            .body = self.response_body[0..output.interface.end],
        };
        return self.responseValue(generation);
    }

    fn responseValue(self: *Server, generation: usize) api.HttpResponse {
        return .{
            ._server = self,
            ._generation = generation,
            .status = self.response_options.status,
            .headers = self.response_options.headers,
            .body = self.response_options.body,
        };
    }

    fn validateResponse(self: *Server, options: api.HttpResponseOptions, prefix: ?std.http.Header) !void {
        const status = @backingInt(options.status);
        if (status < 200 or status > 599 or options.body.len > self.response_body.len or
            options.headers.len > self.response_headers.len or
            ((status == 204 or status == 304) and options.body.len != 0))
            return error.InvalidHttpResponse;
        if (prefix != null and options.headers.len == self.response_headers.len) return error.InvalidHttpResponse;
        var available = self.response_text.len;
        if (prefix) |header| try validateExtraHeader(header, &available);
        for (options.headers) |header| try validateExtraHeader(header, &available);
    }

    fn validateExtraHeader(header: std.http.Header, available: *usize) !void {
        if (!validHeader(header)) return error.InvalidHttpResponse;
        inline for (.{ "content-length", "transfer-encoding", "connection", "trailer", "upgrade" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(header.name, reserved)) return error.InvalidHttpResponse;
        }
        for ([_][]const u8{ header.name, header.value }) |text| {
            if (text.len > available.*) return error.InvalidHttpResponse;
            available.* -= text.len;
        }
    }

    fn copyHeader(self: *Server, header: std.http.Header, index: usize, offset: *usize) !void {
        const name = try copyBytes(self.response_text, offset, header.name);
        const value = try copyBytes(self.response_text, offset, header.value);
        self.response_headers[index] = .{ .name = name, .value = value };
    }

    fn copyResponse(self: *Server, options: api.HttpResponseOptions) !void {
        try self.validateResponse(options, null);
        var offset: usize = 0;
        for (options.headers, 0..) |header, i| try self.copyHeader(header, i, &offset);
        @memcpy(self.response_body[0..options.body.len], options.body);
        self.response_options = .{
            .status = options.status,
            .headers = self.response_headers[0..options.headers.len],
            .body = self.response_body[0..options.body.len],
        };
    }

    pub fn send(self: *Server, value: api.HttpResponse) !void {
        try self.claim(value);
        try self.io.checkCancel();
        // A callback may catch generic Reader.ReadFailed, but cannot turn run
        // cancellation into a successful response.
        if (self.input.err) |err| if (err == error.Canceled) return err;
        if (self.output.err) |err| if (err == error.Canceled) return err;
        if (self.deadline.untilNow(self.io).raw.nanoseconds >= 0) return error.Timeout;
        // An unread body must not cause an implicit 100 or unbounded discard.
        self.request.head.expect = null;
        self.request.respond(value.body, .{
            .version = self.request.head.version,
            .status = value.status,
            .extra_headers = value.headers,
            .keep_alive = false,
            .transfer_encoding = if (value.status == .no_content) .none else null,
        }) catch |err| return self.output.err orelse err;
    }

    pub fn completionOwner(self: *Server) completion.Owner {
        return .{ .context = self, .acquire_fn = acquireDelivery, .peek_fn = peekDelivery, .abort_fn = abortDelivery };
    }

    fn abortDelivery(context: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(context));
        self.interrupt(self.io);
    }

    fn acquireDelivery(context: *anyopaque) completion.Token {
        const self: *Server = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.pending and self.deliveries != 0);
        self.deliveries += 1;
        return self.token();
    }

    fn peekDelivery(context: *anyopaque) completion.Token {
        const self: *Server = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.pending and self.deliveries != 0);
        return self.token();
    }

    fn token(self: *Server) completion.Token {
        return .{ .context = self, .generation = self.generation, .release_fn = releaseToken };
    }

    fn releaseToken(context: *anyopaque, generation: usize) void {
        const self: *Server = @ptrCast(@alignCast(context));
        self.releaseDelivery(generation);
    }

    fn releaseDelivery(self: *Server, generation: usize) void {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(generation == self.generation and self.deliveries != 0);
        self.deliveries -= 1;
        const complete = self.deliveries == 0;
        self.mutex.unlock(self.io);
        // Completion without a send deliberately closes instead of inventing a
        // response. The producer closes/reuses only after the last delivery.
        if (complete) self.done.set(self.io);
    }

    fn claim(self: *Server, value: api.HttpResponse) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (value._invalid or value._generation != self.generation or !self.pending or self.sent or !self.built)
            return error.InvalidHttpResponse;
        try self.validateResponse(.{ .status = value.status, .headers = value.headers, .body = value.body }, null);
        self.sent = true;
    }
};

// Use the standard fixed writer, recording only actual capacity failures.
// A custom jsonStringify returning WriteFailed is not necessarily an overflow.
const JsonWriter = struct {
    interface: Writer,
    exceeded: bool = false,
    const vtable: Writer.VTable = block: {
        var table = Writer.fixed(@constCast(&.{})).vtable.*;
        table.drain = drain;
        table.rebase = rebase;
        break :block table;
    };

    fn drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *JsonWriter = @fieldParentPtr("interface", writer);
        return Writer.fixedDrain(writer, data, splat) catch |err| {
            self.exceeded = true;
            return err;
        };
    }
    fn rebase(writer: *Writer, _: usize, _: usize) Writer.Error!void {
        const self: *JsonWriter = @fieldParentPtr("interface", writer);
        self.exceeded = true;
        return error.WriteFailed;
    }
};

fn copyBytes(storage: []u8, offset: *usize, value: []const u8) ![]const u8 {
    if (value.len > storage.len - offset.*) return error.InvalidHttpResponse;
    const destination = storage[offset.*..][0..value.len];
    @memcpy(destination, value);
    offset.* += value.len;
    return destination;
}

fn validHeader(header: std.http.Header) bool {
    if (header.name.len == 0) return false;
    for (header.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    }
    for (header.value) |byte| {
        if ((byte < 32 and byte != '\t') or byte == 127) return false;
    }
    return true;
}

// Small standard Reader/Writer adapters add an absolute deadline to the
// standard net operations. HTTP framing/parsing stays entirely in std.http.
const Input = struct {
    server: *Server,
    timeout: std.Io.Timeout,
    err: ?anyerror = null,
    interface: Reader,

    fn read(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        if (limit == .nothing) return 0;
        const self: *Input = @alignCast(@fieldParentPtr("interface", reader));
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        var data = [_][]u8{destination};
        const result = operate(self.server.io, .{ .net_read = .{
            .socket_handle = self.server.connection.?.socket.handle,
            .data = &data,
        } }, self.timeout.deadline) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        const value = result.net_read catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (value.data_len == 0) return error.EndOfStream;
        writer.advance(value.data_len);
        return value.data_len;
    }
};

const Output = struct {
    server: *Server,
    err: ?anyerror = null,
    interface: Writer,

    fn write(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Output = @alignCast(@fieldParentPtr("interface", writer));
        const result = operate(self.server.io, .{ .net_write = .{
            .socket_handle = self.server.connection.?.socket.handle,
            .header = writer.buffered(),
            .data = data,
            .splat = splat,
        } }, self.server.deadline) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        const n = result.net_write catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        return writer.consume(n);
    }
};

// Batch timeouts may be spurious (including poll's millisecond rounding).
// Preserve the absolute deadline and always cancel/join pending operations.
fn operate(io: std.Io, operation: std.Io.Operation, deadline: std.Io.Clock.Timestamp) !std.Io.Operation.Result {
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, operation);
    while (true) {
        batch.awaitConcurrent(io, .{ .deadline = deadline }) catch |err| {
            if (err == error.Timeout and deadline.untilNow(io).raw.nanoseconds < 0) continue;
            return err;
        };
        return batch.next().?.result;
    }
}

const Body = struct {
    server: *Server,
    input: *Reader = undefined,
    used: usize = 0,
    err: ?anyerror = null,
    interface: Reader,

    fn read(reader: *Reader, writer: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        if (limit == .nothing) return 0;
        const self: *Body = @alignCast(@fieldParentPtr("interface", reader));
        if (self.err != null) return error.ReadFailed;
        const remaining = self.server.config.request_body_bytes - self.used;
        if (remaining == 0) {
            _ = self.input.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => {
                    self.failure(err);
                    return err;
                },
            };
            self.err = error.HttpBodyTooLarge;
            return error.ReadFailed;
        }
        const n = self.input.stream(writer, limit.min(.limited(remaining))) catch |err| {
            if (err == error.EndOfStream and self.server.http.reader.state != .ready) {
                self.err = error.HttpInvalidBody;
                return error.ReadFailed;
            }
            if (err == error.ReadFailed) self.failure(err);
            return err;
        };
        self.used += n;
        return n;
    }

    fn failure(self: *Body, err: anyerror) void {
        const cause = if (self.server.input.err) |cause|
            cause
        else if (self.server.http.reader.body_err) |cause|
            cause
        else
            err;
        self.err = switch (cause) {
            error.HttpChunkInvalid, error.HttpChunkTruncated, error.HttpHeadersOversize => error.HttpInvalidBody,
            else => cause,
        };
    }
};
