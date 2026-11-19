//! An HTTP/1.1 server as a source, an operator and a few handlers, on top
//! of `std.http.Server`.
//!
//!     const api = pipe(.{
//!         recover(http.fail),
//!         route(.{
//!             when(http.path("/sum"), .{ map(sum), http.text("{d}") }),
//!             otherwise(.{http.status(.not_found)}),
//!         }),
//!     });
//!     const server = program(http.connections(), .{
//!         concurrent(64, .{ recover(http.disconnected), http.serve(api) }),
//!     }).provide(.{http.listen(address, .{})});
//!
//! `listen` binds the listener for the run, `connections` accepts from it,
//! and `serve` holds the conversation on one connection: it reads requests
//! and pushes each as a `Request` through a copy of its pipe that it
//! constructs for that connection, with a `Response` added to the
//! dependencies. The responders (`text`, `json`, `status`) and `fail` find
//! the request to answer through that dependency, so they only work inside
//! the pipe given to `serve`.
//!
//! Nothing here is known to the core: `serve` holds a sub-pipe the way
//! `concurrent` does and runs it by direct call on the task it is pushed on.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Flow = core.Flow;
const End = core.End;
const Closed = core.Closed;

pub const Status = std.http.Status;
pub const Method = std.http.Method;

/// A request head larger than this is answered 431 and the connection closed.
pub const head_bytes = 8 * 1024;
/// Responses are collected in a buffer of this size per connection.
pub const output_bytes = 4 * 1024;

/// What a handler returns to choose the status `fail` answers with. Any
/// other error is answered 500.
pub const Error = error{
    /// 400
    BadRequest,
    /// 404
    NotFound,
    /// 405
    MethodNotAllowed,
    /// 411
    LengthRequired,
    /// 413
    PayloadTooLarge,
    /// 417
    ExpectationFailed,
};

fn expectProvided(comptime Env: type, comptime T: type, comptime message: []const u8) void {
    if (!di.has(Env, T)) @compileError(message);
}

// ---------------------------------------------------------------------------
// Listening and accepting
// ---------------------------------------------------------------------------

/// The listener bound by `listen`, as a dependency.
pub const Listener = struct {
    server: *Io.net.Server,

    /// The port it listens on: the one the system chose when asked for port 0.
    pub fn port(listener: Listener) u16 {
        return listener.server.socket.address.getPort();
    }
};

/// Listens on `address` for the duration of a program and provides the
/// `Listener`. Pass it to `Program.provide`. Needs `std.Io`.
pub fn listen(address: Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Listen {
    return .{ .address = address, .options = options };
}

const Listen = struct {
    address: Io.net.IpAddress,
    options: Io.net.IpAddress.ListenOptions,

    pub const zrx_resource = {};
    pub const Provides = Listener;
    pub const needs: []const type = &.{Io};

    pub fn bind(self: @This(), env: anytype, next: anytype) !void {
        const io = di.get(env, Io);
        var server = try self.address.listen(io, self.options);
        defer server.deinit(io);
        return next.call(Listener{ .server = &server });
    }
};

/// An accepted connection. `serve` owns it from the push on and closes it
/// when the conversation is over, however it ended.
pub const Connection = struct { stream: Io.net.Stream };

/// A connection over a reader and a writer of the caller's: a test, or a
/// stream that is not a socket. `serve` reads, writes and flushes, and
/// closes nothing. The reader's buffer bounds the request head.
pub const Transport = struct { reader: *Io.Reader, writer: *Io.Writer };

/// The connections accepted from the `Listener`, until a push answers
/// `.done`. A connection the peer gave up before it was accepted is skipped;
/// any other failure to accept fails the run.
pub fn connections() Connections {
    return .{};
}

const Connections = struct {
    pub const zrx_source = {};
    pub const Item = Connection;

    pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
        const Env = @TypeOf(env);
        comptime expectProvided(Env, Listener, "http.connections: needs a listener; bind one with `program(...).provide(.{ http.listen(address, .{}) })`");
        comptime expectProvided(Env, Io, "http.connections: needs `std.Io` to accept connections; pass `io` to `run(.{ io, ... })`");
        const io = di.get(env, Io);
        const listener = di.get(env, Listener);
        while (true) {
            const stream = listener.server.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => |e| return e,
            };
            if (try down.push(Connection{ .stream = stream }) == .done) return;
        }
    }
};

// ---------------------------------------------------------------------------
// One connection
// ---------------------------------------------------------------------------

/// The state of one connection: what `Request` and `Response` point at.
const Exchange = struct {
    server: std.http.Server,
    /// The request being answered; valid while `pending`.
    request: std.http.Server.Request,
    /// A request was pushed and has not been answered yet.
    pending: bool,
    /// Something was answered that no request asked for, so nothing valid
    /// can follow on this connection.
    broken: bool,

    /// Writes the response head. Returns where to write `length` bytes of
    /// body, or null when none is to be written.
    fn begin(x: *Exchange, code: Status, content_type: ?[]const u8, length: usize) Io.Writer.Error!?*Io.Writer {
        if (!x.pending) {
            x.broken = true;
            return null;
        }
        x.pending = false;
        const request = &x.request;
        // Answering instead of reading the body the client is still waiting
        // to send, or after reading part of it, ends the connection.
        if (request.head.expect != null or !x.bodySettled()) request.head.keep_alive = false;
        request.head.expect = null;
        const headers = [_]std.http.Header{.{ .name = "content-type", .value = content_type orelse "" }};
        _ = request.respondStreaming(&.{}, .{
            .content_length = length,
            .respond_options = .{
                .status = code,
                .keep_alive = request.head.keep_alive,
                .extra_headers = if (content_type != null) &headers else &.{},
            },
        }) catch |err| switch (err) {
            error.HttpExpectationFailed => unreachable, // cleared above
            error.WriteFailed => return error.WriteFailed,
        };
        return if (request.head.method == .HEAD) null else x.server.out;
    }

    /// Whether the next request can be found behind this one: its body was
    /// read to the end, it has none, or `std` can skip it.
    fn bodySettled(x: *const Exchange) bool {
        const head = &x.request.head;
        const chunked = head.transfer_encoding != .none;
        return switch (x.server.reader.state) {
            .ready => true,
            .received_head => if (head.method.requestHasBody())
                chunked != (head.content_length != null)
            else
                !chunked and (head.content_length orelse 0) == 0,
            else => false,
        };
    }

    /// Whether another request may be read from this connection.
    fn reusable(x: *const Exchange) bool {
        return !x.broken and x.request.head.keep_alive and x.server.reader.state == .ready;
    }

    /// Why reading the body failed: the peer's framing, or the connection.
    fn bodyFailure(x: *const Exchange) Request.BodyError {
        const err = x.server.reader.body_err orelse return error.ReadFailed;
        return if (err == error.HttpChunkInvalid) error.BadRequest else error.ReadFailed;
    }
};

/// A request, as the item of the pipe given to `serve`. It points into the
/// connection: use it while its push is running, and read the head (path,
/// query, headers) before the body, which overwrites it.
pub const Request = struct {
    exchange: *Exchange,

    pub const Pair = struct { name: []const u8, value: []const u8 };

    /// The pairs of a query string, as sent: nothing is percent-decoded.
    pub const Query = struct {
        pairs: std.mem.SplitIterator(u8, .scalar),

        pub fn next(query_pairs: *Query) ?Pair {
            while (query_pairs.pairs.next()) |pair| {
                if (pair.len == 0) continue;
                const split = std.mem.findScalar(u8, pair, '=') orelse pair.len;
                return .{ .name = pair[0..split], .value = pair[@min(split + 1, pair.len)..] };
            }
            return null;
        }
    };

    pub const BodyError = error{ BadRequest, LengthRequired, PayloadTooLarge, ExpectationFailed, ReadFailed, WriteFailed };

    fn head(request: Request) *std.http.Server.Request.Head {
        std.debug.assert(request.exchange.server.reader.state == .received_head); // the body overwrites the head
        return &request.exchange.request.head;
    }

    pub fn method(request: Request) Method {
        return request.exchange.request.head.method;
    }

    /// The target up to its `?`, as sent.
    pub fn path(request: Request) []const u8 {
        const target = request.head().target;
        return target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
    }

    /// The pairs after the target's `?`.
    pub fn query(request: Request) Query {
        const target = request.head().target;
        const start = std.mem.findScalar(u8, target, '?') orelse return .{ .pairs = std.mem.splitScalar(u8, "", '&') };
        return .{ .pairs = std.mem.splitScalar(u8, target[start + 1 ..], '&') };
    }

    /// The value of the first header called `name`, whatever its case.
    pub fn header(request: Request, name: []const u8) ?[]const u8 {
        var all = request.exchange.request.iterateHeaders();
        while (all.next()) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        return null;
    }

    /// The whole body, read into `buffer`; empty for a request that has
    /// none. Call it at most once. Its failures are what `fail` answers:
    ///
    /// - `BadRequest`: a body on a method that takes none, both a length and
    ///   chunked framing, or an invalid chunk;
    /// - `LengthRequired`: a body method with neither;
    /// - `PayloadTooLarge`: more than `buffer` holds;
    /// - `ExpectationFailed`: an `Expect` other than `100-continue`.
    ///
    /// After any of them the connection is closed once the request is
    /// answered. `ReadFailed` and `WriteFailed` are the connection's own.
    pub fn body(request: Request, buffer: []u8) BodyError![]u8 {
        const x = request.exchange;
        const fields = request.head();
        const length = fields.content_length;
        const chunked = fields.transfer_encoding != .none;
        errdefer fields.keep_alive = false;
        if (!fields.method.requestHasBody()) {
            if (chunked or (length orelse 0) != 0) return error.BadRequest;
            return buffer[0..0];
        }
        if (chunked and length != null) return error.BadRequest;
        if (!chunked and length == null) return error.LengthRequired;
        if (length) |n| if (n > buffer.len) return error.PayloadTooLarge;
        const reader = x.request.readerExpectContinue(&.{}) catch |err| switch (err) {
            error.HttpExpectationFailed => return error.ExpectationFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        const n = reader.readSliceShort(buffer) catch return x.bodyFailure();
        if (x.server.reader.state != .ready) {
            // The buffer is full and the body is not over, or the peer is gone.
            var more: [1]u8 = undefined;
            if ((reader.readSliceShort(&more) catch return x.bodyFailure()) != 0) return error.PayloadTooLarge;
            if (x.server.reader.state != .ready) return error.ReadFailed;
        }
        return buffer[0..n];
    }
};

/// The answer to the request being handled, as a dependency of the pipe
/// given to `serve`. The responders use it; a handler of your own can too.
pub const Response = struct {
    exchange: *Exchange,

    /// Answers the request with `content`. Each request is answered once:
    /// a second answer writes nothing and closes the connection.
    pub fn send(response: Response, code: Status, content_type: ?[]const u8, content: []const u8) Io.Writer.Error!void {
        const out = try response.exchange.begin(code, content_type, content.len) orelse return;
        try out.writeAll(content);
    }
};

/// Serves each connection it is given with `sub`, a terminated synchronous
/// pipe of `Request` items: an operator tuple or a `pipe(...)`. Terminal.
///
/// The pipe is constructed anew for every connection, with that
/// connection's `Response` among its dependencies, and finished when the
/// connection ends. Requests are read while the peer keeps the connection
/// alive and the pipe wants more; a request the pipe did not answer is
/// answered 500. Output is flushed when no further request is waiting in
/// the read buffer, so pipelined requests share a write.
///
/// A head that does not parse is answered 400, one larger than `head_bytes`
/// 431, and the connection closed. A connection that breaks fails the push
/// with `error.ReadFailed` or `error.WriteFailed`: put
/// `recover(http.disconnected)` before `serve` so that it does not fail the run.
pub fn serve(sub: anytype) Serve(core.NormalizedPipe("http.serve", @TypeOf(sub))) {
    return .{ .pipe = core.normalizePipe("http.serve", sub) };
}

fn Serve(comptime P: type) type {
    return struct {
        pipe: P,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "http.serve";

        fn SubEnv(comptime Env: type) type {
            return di.Extend(Env, Response);
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            if (In != Connection and In != Transport) @compileError(
                "http.serve: items must be `http.Connection` (from `http.connections()`) or `http.Transport`, got `" ++ @typeName(In) ++ "`",
            );
            if (In == Connection) expectProvided(Env, Io, "http.serve: needs `std.Io` to read and write a connection; pass `io` to `run(.{ io, ... })`");
            const Left = P.Out(SubEnv(Env), Request);
            if (Left != End) @compileError(
                "http.serve: the pipe must answer every request, but it still emits `" ++ @typeName(Left) ++
                    "`; end it with http.text(...), http.json(), http.status(...) or another terminal operator",
            );
            if (P.Stage(SubEnv(Env), Request).has_boundary) @compileError(
                "http.serve: the pipe contains a task boundary; a connection is served on one task, so put queue(...) and concurrent(...) around http.serve(...), not inside it",
            );
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            @setEvalBranchQuota(di.quota);
            _ = Out(Env, In);
            const Chain = P.Stage(SubEnv(Env), Request);
            return struct {
                op: *const Op,
                env: Env,

                const Self = @This();

                pub fn init(self: *Self, op: *const Op, env: Env) void {
                    self.op = op;
                    self.env = env;
                }

                pub fn push(self: *Self, connection: In, _: anytype) !Flow {
                    if (In == Transport) {
                        try self.converse(connection.reader, connection.writer);
                        return .more;
                    }
                    const io = di.get(self.env, Io);
                    defer connection.stream.close(io);
                    var in_buffer: [head_bytes]u8 = undefined;
                    var out_buffer: [output_bytes]u8 = undefined;
                    var reader = connection.stream.reader(io, &in_buffer);
                    var writer = connection.stream.writer(io, &out_buffer);
                    self.converse(&reader.interface, &writer.interface) catch |err| {
                        // `std` reports a cancelled read or write as a failed
                        // one and records which it was.
                        if (reader.err) |cause| if (cause == error.Canceled) return error.Canceled;
                        if (writer.err) |cause| if (cause == error.Canceled) return error.Canceled;
                        return err;
                    };
                    return .more;
                }

                fn converse(self: *const Self, in: *Io.Reader, out: *Io.Writer) !void {
                    var exchange: Exchange = .{ .server = .init(in, out), .request = undefined, .pending = false, .broken = false };
                    var chain: Chain = undefined;
                    chain.init(&self.op.pipe, di.extend(self.env, Response{ .exchange = &exchange }));
                    while (true) {
                        // The peer waits for what was answered so far only
                        // if it has sent nothing more.
                        if (in.bufferedLen() == 0) try out.flush();
                        exchange.request = exchange.server.receiveHead() catch |err| switch (err) {
                            error.HttpConnectionClosing, error.HttpRequestTruncated => break,
                            error.HttpHeadersOversize => {
                                try refuse(out, .request_header_fields_too_large);
                                break;
                            },
                            error.HttpHeadersInvalid => {
                                try refuse(out, .bad_request);
                                break;
                            },
                            error.ReadFailed => return error.ReadFailed,
                        };
                        exchange.pending = true;
                        const wants_more = try chain.push(Request{ .exchange = &exchange }, Closed{}) == .more;
                        if (exchange.pending) _ = try exchange.begin(.internal_server_error, null, 0);
                        if (!wants_more or !exchange.reusable()) break;
                    }
                    try chain.finish(Closed{});
                    try out.flush();
                }
            };
        }
    };
}

/// Answers what could not be read as a request.
fn refuse(out: *Io.Writer, code: Status) Io.Writer.Error!void {
    try out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{ @backingInt(code), code.phrase() orelse "" });
}

// ---------------------------------------------------------------------------
// Responders
// ---------------------------------------------------------------------------

fn Responder(comptime who: []const u8, comptime Answer: type) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = who;

        pub fn Out(comptime Env: type, comptime _: type) type {
            expectProvided(Env, Response, who ++ ": answers a request, so it belongs in the pipe given to `http.serve(...)`; no `http.Response` is provided here");
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                exchange: *Exchange,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.exchange = di.get(env, Response).exchange;
                }

                pub fn push(self: *@This(), item: In, _: anytype) Io.Writer.Error!Flow {
                    try Answer.send(self.exchange, item);
                    return .more;
                }
            };
        }
    };
}

/// Ends the pipe by answering 200 with the item formatted as `text/plain`:
/// `http.text("{d}")`. A tuple item supplies several format arguments.
pub fn text(comptime format: []const u8) Responder("http.text", Text(format)) {
    return .{};
}

fn Text(comptime format: []const u8) type {
    return struct {
        fn send(x: *Exchange, item: anytype) Io.Writer.Error!void {
            const args = if (comptime di.isTuple(@TypeOf(item))) item else .{item};
            const out = try x.begin(.ok, "text/plain", std.fmt.count(format, args)) orelse return;
            try out.print(format, args);
        }
    };
}

/// Ends the pipe by answering 200 with the item as `application/json`,
/// written by `std.json`.
pub fn json() Responder("http.json", Json) {
    return .{};
}

const Json = struct {
    fn send(x: *Exchange, item: anytype) Io.Writer.Error!void {
        var scratch: [64]u8 = undefined;
        var counted: Io.Writer.Discarding = .init(&scratch);
        try std.json.Stringify.value(item, .{}, &counted.writer);
        const out = try x.begin(.ok, "application/json", @intCast(counted.fullCount())) orelse return;
        try std.json.Stringify.value(item, .{}, out);
    }
};

/// Ends the pipe by answering `code` with an empty body, whatever the item.
pub fn status(comptime code: Status) Responder("http.status", Coded(code)) {
    return .{};
}

fn Coded(comptime code: Status) type {
    return struct {
        fn send(x: *Exchange, _: anytype) Io.Writer.Error!void {
            _ = try x.begin(code, null, 0);
        }
    };
}

// ---------------------------------------------------------------------------
// Predicates and recover handlers
// ---------------------------------------------------------------------------

fn requestOf(comptime who: []const u8, args: anytype) Request {
    if (comptime (args.len != 1 or @TypeOf(args[0]) != Request)) @compileError(
        who ++ ": tests an `http.Request`, got " ++ di.listTypes(di.types(@TypeOf(args))) ++
            "; use it in the pipe given to `http.serve(...)`, before the request is mapped to something else",
    );
    return args[0];
}

/// A predicate: the request's path is exactly `expected`.
pub fn path(comptime expected: []const u8) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) bool {
            return std.mem.eql(u8, requestOf("http.path", args).path(), expected);
        }
    };
}

/// A predicate: the request's method is `expected`. Combine it with `path`
/// through `all(.{ ... })`.
pub fn method(comptime expected: Method) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) bool {
            return requestOf("http.method", args).method() == expected;
        }
    };
}

/// For `recover`, in the pipe given to `serve`: answers a request whose
/// handling failed with the status of its error (see `Error`; anything else
/// is 500). The connection goes on unless the request's body was left
/// unread in a way that hides where the next request begins. A broken
/// connection is not answered: its error passes on to `disconnected`.
pub fn fail(response: Response, err: anyerror, _: anytype) error{ ReadFailed, WriteFailed }!void {
    const code: Status = switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
        error.BadRequest => .bad_request,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.LengthRequired => .length_required,
        error.PayloadTooLarge => .payload_too_large,
        error.ExpectationFailed => .expectation_failed,
        else => .internal_server_error,
    };
    _ = try response.exchange.begin(code, null, 0);
}

/// For `recover`, before `serve`: a connection that broke is dropped and
/// the run goes on. Every other error still fails the run.
pub fn disconnected(_: error{ ReadFailed, WriteFailed }, _: anytype) void {}
