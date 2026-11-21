//! An HTTP/1.1 server as a source, an operator and a few handlers, on top
//! of `std.http.Server`.
//!
//!     const api = pipe(.{
//!         recover(anyerror, .{http.fail()}),
//!         route(.{
//!             when(http.path("/sum"), .{ map(sum), http.text("{d}") }),
//!             otherwise(.{http.status(.not_found)}),
//!         }),
//!     });
//!     const server = program(http.connections(), .{
//!         concurrent(64, .{ recover(http.Disconnected, .{drain()}), http.serve(api) }),
//!     }).provide(.{http.listen(address, .{})});
//!
//! `listen` binds the listener for the run, `connections` accepts from it,
//! and `serve` holds the conversation on one connection: it reads requests
//! and pushes each as a `Request` through a copy of its pipe that it
//! constructs for that connection, with a `Response` added to the
//! dependencies. The responders (`text`, `json`, `status`, `fail`) find
//! the request to answer through that dependency, so they only work inside
//! the pipe given to `serve`. A connection that is not to be served goes to
//! `reject`, which closes it.
//!
//! Nothing here is known to the core: `serve` holds a sub-pipe the way
//! `concurrent` does and runs it by direct call on the task it is pushed on.
const std = @import("std");
const Io = std.Io;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const transform = @import("../ops/transform.zig");
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
    /// The connections accepted from it that no worker has taken yet.
    waiting: *Waiting,

    /// The port it listens on: the one the system chose when asked for port 0.
    pub fn port(listener: Listener) u16 {
        return listener.server.socket.address.getPort();
    }
};

pub const ListenOptions = struct {
    /// How many accepted connections may wait for a `serve` or a `reject`
    /// at once. The listener holds them in a table of this size; while it
    /// is full, `connections` accepts no more.
    pending: usize = 64,
    /// Sets SO_REUSEADDR (and SO_REUSEPORT on POSIX) on the listening socket.
    reuse_address: bool = false,
    /// How many connections the kernel accepts on the server's behalf.
    kernel_backlog: u31 = Io.net.default_kernel_backlog,
};

/// Listens on `address` for the duration of a program and provides the
/// `Listener`. Pass it to `provide` or `run`. Needs `std.Io`.
///
/// The listener owns every connection `connections` accepted until a
/// `serve` or a `reject` takes it, and closes those nobody took once the
/// run is over.
pub fn listen(address: Io.net.IpAddress, comptime options: ListenOptions) Listen(options) {
    return .{ .address = address };
}

fn Listen(comptime options: ListenOptions) type {
    if (options.pending == 0) @compileError("http.listen: `pending` must be at least 1; it is how many accepted connections may wait for a worker");
    return struct {
        address: Io.net.IpAddress,

        pub const zrx_resource = {};
        pub const Provides = Listener;
        pub const needs: []const type = &.{Io};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const io = di.get(env, Io);
            var server = try self.address.listen(io, .{ .reuse_address = options.reuse_address, .kernel_backlog = options.kernel_backlog });
            defer server.deinit(io);
            var slots: [options.pending]Waiting.Slot = @splat(.{});
            var waiting: Waiting = .{ .slots = &slots };
            // Every task of the run has returned by the time this runs.
            defer waiting.closeAll(io);
            return next.call(Listener{ .server = &server, .waiting = &waiting });
        }
    };
}

/// The connections that were accepted and that neither a `serve` nor a
/// `reject` has taken yet. A connection in a queue, or in the hands of a
/// source whose push was cancelled, would otherwise be closed by nobody.
/// One that a stage dropped or keeps stays here as well: nothing tells the
/// listener that it will never be taken.
const Waiting = struct {
    mutex: Io.Mutex = .init,
    freed: Io.Condition = .init,
    slots: []Slot,
    /// Slots that hold a connection or are promised to an accept under way.
    used: usize = 0,

    const Slot = struct {
        stream: ?Io.net.Stream = null,
        /// Counts the connections this slot has held, so that the one it
        /// holds can be told from a copy of an earlier one.
        generation: u64 = 0,
    };

    /// Waits for room for one more connection and reserves it.
    fn reserve(waiting: *Waiting, io: Io) Io.Cancelable!void {
        try waiting.mutex.lock(io);
        defer waiting.mutex.unlock(io);
        while (waiting.used == waiting.slots.len) try waiting.freed.wait(io, &waiting.mutex);
        waiting.used += 1;
    }

    /// Gives back a reservation that no connection came for.
    fn release(waiting: *Waiting, io: Io) void {
        waiting.mutex.lockUncancelable(io);
        defer waiting.mutex.unlock(io);
        waiting.used -= 1;
        waiting.freed.signal(io);
    }

    /// Puts an accepted connection into the room reserved for it.
    fn hold(waiting: *Waiting, io: Io, stream: Io.net.Stream) Connection.Held {
        waiting.mutex.lockUncancelable(io);
        defer waiting.mutex.unlock(io);
        for (waiting.slots) |*slot| if (slot.stream == null) {
            slot.stream = stream;
            slot.generation += 1;
            return .{ .by = waiting, .slot = slot, .generation = slot.generation };
        };
        unreachable; // room was reserved
    }

    /// Hands the connection to the caller, who closes it from here on, and
    /// frees its room. False when the room no longer holds that connection:
    /// a copy of it was taken before, and the room may hold another by now.
    fn take(waiting: *Waiting, io: Io, held: Connection.Held) bool {
        waiting.mutex.lockUncancelable(io);
        defer waiting.mutex.unlock(io);
        const slot = held.slot;
        if (slot.stream == null or slot.generation != held.generation) return false;
        slot.stream = null;
        waiting.used -= 1;
        waiting.freed.signal(io);
        return true;
    }

    fn closeAll(waiting: *Waiting, io: Io) void {
        for (waiting.slots) |slot| if (slot.stream) |stream| stream.close(io);
    }
};

/// An accepted connection. The listener owns it until it is pushed to a
/// `serve`, which closes it when the conversation is over, however it
/// ended, or to a `reject`, which closes it at once. Every connection has
/// to end in one of the two: one that a stage drops or keeps back stays
/// open, and counts as waiting (`pending`), until the run is over.
///
/// It is handed over once. A copy that reaches a `serve` or a `reject`
/// after the connection was taken (a `branch` into two of them) fails that
/// push with `error.ConnectionTaken`, and the socket is left to whoever
/// took it.
pub const Connection = struct {
    stream: Io.net.Stream,
    /// Where the listener holds it until then. Null for a stream of your
    /// own, which nothing keeps track of: push it to one `serve` or `reject`.
    held: ?Held = null,

    const Held = struct { by: *Waiting, slot: *Waiting.Slot, generation: u64 };

    /// Makes the caller the one who closes the connection.
    fn claim(connection: Connection, io: Io) error{ConnectionTaken}!void {
        const held = connection.held orelse return;
        if (!held.by.take(io, held)) return error.ConnectionTaken;
    }
};

/// A connection over a reader and a writer of the caller's: a test, or a
/// stream that is not a socket. `serve` reads, writes and flushes, and
/// closes nothing. The reader's buffer bounds the request head.
pub const Transport = struct { reader: *Io.Reader, writer: *Io.Writer };

/// The connections accepted from the `Listener`, until a push answers
/// `.done`. A connection the peer gave up before it was accepted is skipped;
/// any other failure to accept fails the run. While as many connections wait
/// for a `serve` or a `reject` as the listener has room for (`pending`), no
/// more are accepted.
///
/// It finds out that the pipe is done at a push, not while it waits to
/// accept: limit connections before a task boundary (`take(n)`), not after.
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
        const waiting = listener.waiting;
        while (true) {
            try waiting.reserve(io);
            const stream = listener.server.accept(io) catch |err| {
                waiting.release(io);
                switch (err) {
                    error.ConnectionAborted => continue,
                    else => |e| return e,
                }
            };
            // From here the listener closes the connection unless a `serve`
            // or a `reject` takes it: also when this push fails or is
            // answered `.done`.
            const held = waiting.hold(io, stream);
            if (try down.push(Connection{ .stream = stream, .held = held }) == .done) return;
        }
    }
};

/// Turns away each connection it is given: closes it without reading or
/// answering anything, which frees its room with the listener. Terminal.
///
/// This is how a pipe lets go of a connection it will not serve:
///
///     route(.{
///         when(unwelcome, .{http.reject()}),
///         otherwise(.{http.serve(api)}),
///     })
pub fn reject() Reject {
    return .{};
}

const Reject = struct {
    pub const zrx_operator = {};
    pub const name = "http.reject";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (In != Connection) @compileError(
            "http.reject: items must be `http.Connection` (from `http.connections()`), got `" ++ @typeName(In) ++ "`",
        );
        expectProvided(Env, Io, "http.reject: needs `std.Io` to close a connection; pass `io` to `run(.{ io, ... })`");
        return End;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        _ = Out(Env, In);
        return struct {
            io: Io,

            pub fn init(self: *@This(), _: *const Reject, env: Env) void {
                self.io = di.get(env, Io);
            }

            pub fn push(self: *@This(), connection: In, _: anytype) error{ConnectionTaken}!Flow {
                try connection.claim(self.io);
                connection.stream.close(self.io);
                return .more;
            }
        };
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
    /// What `std` recorded of the socket's failures; null for a reader and
    /// a writer of the caller's, where only an error that comes back tells.
    socket: ?Recorded,

    /// A failed connection: nothing more is read from or written to it.
    const Lost = error{ ReadFailed, WriteFailed };

    /// The failure of a read or a write that nobody reported: a handler
    /// may have taken it, and `std` keeps the one it meets while it skips
    /// a body.
    fn intact(x: *const Exchange) Lost!void {
        const socket = x.socket orelse return;
        if (socket.reader.err != null) return error.ReadFailed;
        if (socket.writer.err != null) return error.WriteFailed;
    }

    /// Writes the response head. Returns where to write `length` bytes of
    /// body, or null when none is to be written.
    fn begin(x: *Exchange, code: Status, content_type: ?[]const u8, length: usize) Lost!?*Io.Writer {
        if (!x.pending) {
            x.broken = true;
            return null;
        }
        if (code.class() == .informational) {
            // An interim response answers nothing: sent as the answer, it
            // would leave the peer waiting for the final one.
            _ = try x.begin(.internal_server_error, null, 0);
            return null;
        }
        x.pending = false;
        const head = &x.request.head;
        // Answering instead of reading the body the client is still waiting
        // to send, or after reading part of it, ends the connection.
        if (head.expect != null or !x.bodySettled()) head.keep_alive = false;
        head.expect = null;
        // If the connection failed while the handler read the body, and
        // the handler went on, the answer is not started: one larger than
        // the output buffer would be a write that a run being cancelled
        // has to wait for.
        try x.intact();
        // The head is written here and not by `std`, which skips an unread
        // body first. That read would overwrite the request's head, which
        // the item being answered may point into.
        const out = x.server.out;
        try out.print("HTTP/1.1 {d} {s}\r\n", .{ @backingInt(code), code.phrase() orelse "" });
        if (!head.keep_alive) try out.writeAll("connection: close\r\n");
        // A 204 must not carry a length (RFC 9110, 8.6); a 304 may only
        // carry that of the representation it does not send, which is not
        // known here. A 205 has no content (15.3.6): its length is zero and
        // nothing follows its head, whatever it was given.
        const empty = code == .reset_content;
        if (!bodyless(code)) try out.print("content-length: {d}\r\n", .{if (empty) 0 else length});
        const content = !bodyless(code) and !empty;
        if (content) if (content_type) |media| try out.print("content-type: {s}\r\n", .{media});
        try out.writeAll("\r\n");
        return if (content and head.method != .HEAD) out else null;
    }

    /// Whether the next request can be found behind this one: its body was
    /// read to the end, it has none, or it has a length and can be skipped.
    fn bodySettled(x: *const Exchange) bool {
        const head = &x.request.head;
        return switch (x.server.reader.state) {
            .ready => true,
            .received_head => unread: {
                const length = head.content_length orelse break :unread !head.method.requestHasBody();
                break :unread length == 0 or head.method.requestHasBody();
            },
            else => false,
        };
    }

    /// Sends what was answered so far unless the rest of this request's body
    /// is already in the read buffer: reading or skipping it may wait for the
    /// peer, who may be waiting for those answers.
    fn flushBeforeBody(x: *Exchange) Io.Writer.Error!void {
        if (x.server.reader.state != .received_head) return;
        const length = x.request.head.content_length orelse return;
        if (x.server.reader.in.bufferedLen() >= length) return;
        try x.server.out.flush();
    }

    /// Once the pipe is through with a request: reads past a body it left
    /// unread, and says whether another request may be read from this
    /// connection. Not before, because the read overwrites the request's
    /// head, which items in the pipe may point into.
    fn settle(x: *Exchange) Lost!bool {
        if (x.broken or !x.request.head.keep_alive) return false;
        if (x.server.reader.state != .received_head) return true;
        // A method without a body has none to skip. Do not ask `std` for
        // its reader all the same: that is one shared constant, and
        // discarding from it writes to it, which is a fault where
        // constants are read-only (Linux, in ReleaseFast).
        if (!x.request.head.method.requestHasBody()) return true;
        try x.flushBeforeBody();
        const body = x.request.readerExpectContinue(&.{}) catch |err| switch (err) {
            error.HttpExpectationFailed => unreachable, // cleared by `begin`
            error.WriteFailed => return error.WriteFailed,
        };
        // A body with a length: all that can fail is the read. If the peer
        // ended the connection inside it, the next read finds that out.
        _ = body.discardRemaining() catch return error.ReadFailed;
        return true;
    }
};

/// 204 and 304 end with their head (RFC 9110, 15.3.5 and 15.4.5): they are
/// written without a body and without a length.
fn bodyless(code: Status) bool {
    return code == .no_content or code == .not_modified;
}

/// A request, as the item of the pipe given to `serve`. It points into the
/// connection: use it while its push is running, and read the head (path,
/// query, headers) before the body, which overwrites it. Nothing else does
/// while the push runs.
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
    /// - `BadRequest`: a body on a method that takes none;
    /// - `LengthRequired`: a method that takes one, without a length;
    /// - `PayloadTooLarge`: more than `buffer` holds;
    /// - `ExpectationFailed`: an `Expect` other than `100-continue`.
    ///
    /// After any of them the connection is closed once the request is
    /// answered. `ReadFailed` and `WriteFailed` are the connection's own.
    ///
    /// A body has a length: a request with a `Transfer-Encoding` does not
    /// get here (see `refusal`).
    pub fn body(request: Request, buffer: []u8) BodyError![]u8 {
        const x = request.exchange;
        const fields = request.head();
        errdefer fields.keep_alive = false;
        if (!fields.method.requestHasBody()) {
            if ((fields.content_length orelse 0) != 0) return error.BadRequest;
            return buffer[0..0];
        }
        const length = fields.content_length orelse return error.LengthRequired;
        if (length > buffer.len) return error.PayloadTooLarge;
        try x.flushBeforeBody();
        const reader = x.request.readerExpectContinue(&.{}) catch |err| switch (err) {
            error.HttpExpectationFailed => return error.ExpectationFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        const n = reader.readSliceShort(buffer) catch return error.ReadFailed;
        // Less than its length: the peer is gone.
        if (x.server.reader.state != .ready) return error.ReadFailed;
        return buffer[0..n];
    }
};

/// The answer to the request being handled, as a dependency of the pipe
/// given to `serve`. The responders use it; a handler of your own can too.
pub const Response = struct {
    exchange: *Exchange,

    pub const SendError = Exchange.Lost;

    /// Answers the request with `content`. Each request is answered once:
    /// a second answer writes nothing and closes the connection.
    ///
    /// `code` is the final status. A 204 or a 304 is written without a body
    /// and without a length, and a 205 with a length of zero, whatever
    /// `content` is. An interim status (1xx) is no answer: the request is
    /// answered 500 in its place.
    ///
    /// Fails with what became of the connection, and then nothing of the
    /// answer was started or not all of it was written.
    pub fn send(response: Response, code: Status, content_type: ?[]const u8, content: []const u8) SendError!void {
        const out = try response.exchange.begin(code, content_type, content.len) orelse return;
        try out.writeAll(content);
    }
};

/// Serves each connection it is given with `sub`, a terminated synchronous
/// pipe of `Request` items: an operator tuple or a `pipe(...)`. Terminal.
///
/// The pipe is constructed anew for every connection, with that
/// connection's `Response` among its dependencies, and finished when the
/// conversation ends without an error. Requests are read while the peer keeps the connection
/// alive and the pipe wants more; a request the pipe did not answer is
/// answered 500. Output is flushed when no further request is waiting in
/// the read buffer, so pipelined requests share a write.
///
/// A head that does not parse is answered 400, one larger than `head_bytes`
/// 431, and the connection closed. A connection that breaks fails the push
/// with `error.ReadFailed` or `error.WriteFailed`: put
/// `recover(http.Disconnected, .{drain()})` before `serve` so that it does not
/// fail the run.
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
                        try self.converse(connection.reader, connection.writer, null);
                        return .more;
                    }
                    const io = di.get(self.env, Io);
                    try connection.claim(io);
                    defer connection.stream.close(io);
                    var in_buffer: [head_bytes]u8 = undefined;
                    var out_buffer: [output_bytes]u8 = undefined;
                    var reader = connection.stream.reader(io, &in_buffer);
                    var writer = connection.stream.writer(io, &out_buffer);
                    const outcome = self.converse(&reader.interface, &writer.interface, .{ .reader = &reader, .writer = &writer });
                    // `std` reports a cancelled read or write as a failed one,
                    // or not at all when it was skipping a body for us, and
                    // records which it was. The request is used up either
                    // way, so it has to come out of here.
                    if (reader.err) |cause| if (cause == error.Canceled) return error.Canceled;
                    if (writer.err) |cause| if (cause == error.Canceled) return error.Canceled;
                    try outcome;
                    return .more;
                }

                fn converse(self: *const Self, in: *Io.Reader, out: *Io.Writer, socket: ?Recorded) !void {
                    var exchange: Exchange = .{ .server = .init(in, out), .request = undefined, .pending = false, .broken = false, .socket = socket };
                    var chain: Chain = undefined;
                    chain.init(&self.op.pipe, di.extend(self.env, Response{ .exchange = &exchange }));
                    return requests(&exchange, &chain, in, out) catch |err| {
                        // When a handler ends the conversation early, the
                        // answers completed before it are still the peer's.
                        // Not so when the connection itself failed: writing
                        // to it again could replace the failure `std`
                        // recorded, a cancellation among them, with that of
                        // the new write. And not when the run is being
                        // cancelled, which is no time to wait on a peer.
                        const lost = err == error.ReadFailed or err == error.WriteFailed or @as(anyerror, err) == error.Canceled;
                        exchange.intact() catch return err;
                        if (!lost) out.flush() catch {};
                        return err;
                    };
                }

                /// The requests of one connection, each through `chain`.
                fn requests(exchange: *Exchange, chain: *Chain, in: *Io.Reader, out: *Io.Writer) !void {
                    while (true) {
                        // The peer may be waiting for what was answered so
                        // far, unless a whole further request is already
                        // here: part of one is no reason to make it wait.
                        if (!headBuffered(in)) try out.flush();
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
                        if (refusal(&exchange.request)) |code| {
                            try refuse(out, code);
                            break;
                        }
                        // The expectation is a token, compared without
                        // regard to case (RFC 9110, 10.1.1); `std` compares
                        // it as written.
                        if (exchange.request.head.expect) |expectation| {
                            if (std.ascii.eqlIgnoreCase(expectation, "100-continue")) exchange.request.head.expect = "100-continue";
                        }
                        // An HTTP/1.0 peer is answered and the connection
                        // closed: it would have to be told that it stays
                        // open, and it knows no interim response, so its
                        // expectation is ignored (RFC 9110, 10.1.1).
                        if (exchange.request.head.version == .@"HTTP/1.0") {
                            exchange.request.head.keep_alive = false;
                            exchange.request.head.expect = null;
                        }
                        exchange.pending = true;
                        const wants_more = try chain.push(Request{ .exchange = exchange }, Closed{}) == .more;
                        // A failure does not always come back as an error:
                        // a handler may have taken it. The conversation is
                        // over all the same, and nothing more is read from
                        // or written to the connection.
                        try exchange.intact();
                        if (exchange.pending) _ = try exchange.begin(.internal_server_error, null, 0);
                        if (!wants_more or !try exchange.settle()) break;
                    }
                    try chain.finish(Closed{});
                    try out.flush();
                }
            };
        }
    };
}

/// A socket: `std` records why a read or a write failed, and a later
/// failure replaces the record. Nothing has failed while both are empty.
const Recorded = struct {
    reader: *const Io.net.Stream.Reader,
    writer: *const Io.net.Stream.Writer,
};

/// What `std` parsed leniently is judged here, before any handler sees the
/// request: a head that a proxy in front could read differently must not be
/// served, or the two disagree on where the next request begins. Returns
/// the status to refuse the request with, or null when it is in order.
///
/// 400:
/// - A target is not empty, and holds no space or control character.
/// - A field is `name ":" value`, and its name is a token: nothing stands
///   between it and the colon (RFC 9112, 5.1).
/// - A value holds no CR, LF or NUL (RFC 9110, 5.5).
/// - `Content-Length` is digits (RFC 9110, 8.6); `std` takes a sign and
///   underscores, and refuses an empty one itself.
/// - There is at most one `Host`, with a valid value, and an HTTP/1.1
///   request has exactly one (RFC 9112, 3.2).
/// - A request is not framed in two ways, by a length and by a transfer
///   coding (RFC 9112, 6.1).
///
/// 411: a request with a `Transfer-Encoding`, whatever it names. No body is
/// read that is framed by one: decoding `chunked` is `std`'s, and its chunk
/// reader takes sizes that are no hexadecimal number and overflows on one
/// of 2^64 - 2 or more, which stops a program built with safety checks.
///
/// And one thing is set right: `close` among several connection options
/// ends the connection (RFC 9112, 9.6), where `std` compares the whole value.
fn refusal(request: *std.http.Server.Request) ?Status {
    const target = request.head.target;
    if (target.len == 0) return .bad_request;
    for (target) |c| if (c <= ' ' or c == 0x7f) return .bad_request;
    var host: ?[]const u8 = null;
    var coded = false;
    var lines = std.mem.splitSequence(u8, request.head_buffer, "\r\n");
    _ = lines.first(); // the request line, which `std` took apart
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse return .bad_request;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!token(name)) return .bad_request;
        for (value) |c| if (c == '\r' or c == '\n' or c == 0) return .bad_request;
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (host != null) return .bad_request;
            host = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            for (value) |c| if (!std.ascii.isDigit(c)) return .bad_request;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            coded = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var options = std.mem.splitScalar(u8, value, ',');
            while (options.next()) |option| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, option, " \t"), "close")) request.head.keep_alive = false;
            }
        }
    }
    const value = host orelse if (request.head.version == .@"HTTP/1.0") "" else return .bad_request;
    if (!hostValue(value)) return .bad_request;
    if (coded) return if (request.head.content_length != null) .bad_request else .length_required;
    return null;
}

/// `*tchar` (RFC 9110, 5.6.2). An empty name is refused by `std`.
fn token(name: []const u8) bool {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    return true;
}

/// `uri-host [ ":" port ]` (RFC 3986, 3.2.2), or nothing at all, which is
/// what a client sends for a target without an authority.
fn hostValue(value: []const u8) bool {
    var rest = value;
    if (rest.len != 0 and rest[0] == '[') {
        const close = std.mem.findScalar(u8, rest, ']') orelse return false;
        if (!ipLiteral(rest[1..close])) return false;
        rest = rest[close + 1 ..];
    } else {
        // A registered name or an IPv4 address: neither holds a colon.
        const end = std.mem.findScalar(u8, rest, ':') orelse rest.len;
        if (!nameText(rest[0..end], "")) return false;
        rest = rest[end..];
    }
    if (rest.len == 0) return true;
    if (rest[0] != ':') return false;
    for (rest[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// What stands between the brackets: an IPv6 address, or an address of a
/// later version, `"v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" )`.
fn ipLiteral(literal: []const u8) bool {
    if (literal.len != 0 and (literal[0] == 'v' or literal[0] == 'V')) {
        const dot = std.mem.findScalar(u8, literal, '.') orelse return false;
        if (dot == 1 or dot + 1 == literal.len) return false;
        for (literal[1..dot]) |c| if (!std.ascii.isHex(c)) return false;
        // No percent-encoding here: `%` is not in the set.
        for (literal[dot + 1 ..]) |c| if (c == '%') return false;
        return nameText(literal[dot + 1 ..], ":");
    }
    // An address as it is written, which leaves out a zone: `%` is no
    // part of one.
    _ = Io.net.Ip6Address.parse(literal, 0) catch return false;
    return true;
}

/// Unreserved characters, sub-delimiters, `also`, and percent-encoded
/// bytes: a `%` is followed by two hexadecimal digits.
fn nameText(name: []const u8, comptime also: []const u8) bool {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (c == '%') {
            if (name.len - i < 3 or !std.ascii.isHex(name[i + 1]) or !std.ascii.isHex(name[i + 2])) return false;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "-._~!$&'()*+,;=" ++ also, c) == null) {
            return false;
        }
    }
    return true;
}

/// Whether a whole request head is in the read buffer, so that reading it
/// does not wait for the peer.
fn headBuffered(in: *Io.Reader) bool {
    return std.mem.find(u8, in.buffered(), "\r\n\r\n") != null;
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

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectProvided(Env, Response, who ++ ": answers a request, so it belongs in the pipe given to `http.serve(...)`; no `http.Response` is provided here");
            if (Answer.sends_item and In == Request) @compileError(
                who ++ ": sends its item, and the item here is still the `http.Request`; put a `map(handler)` before it that returns what to send",
            );
            return End;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                exchange: *Exchange,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.exchange = di.get(env, Response).exchange;
                }

                pub fn push(self: *@This(), item: In, _: anytype) Exchange.Lost!Flow {
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
        const sends_item = true;

        fn send(x: *Exchange, item: anytype) Exchange.Lost!void {
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
    const sends_item = true;

    fn send(x: *Exchange, item: anytype) Exchange.Lost!void {
        var scratch: [64]u8 = undefined;
        var counted: Io.Writer.Discarding = .init(&scratch);
        try std.json.Stringify.value(item, .{}, &counted.writer);
        const out = try x.begin(.ok, "application/json", @intCast(counted.fullCount())) orelse return;
        try std.json.Stringify.value(item, .{}, out);
    }
};

/// Ends the pipe by answering `code` with an empty body, whatever the item.
/// `code` is a final status: an interim one (1xx) is a compile error.
pub fn status(comptime code: Status) Responder("http.status", Coded(code)) {
    return .{};
}

fn Coded(comptime code: Status) type {
    if (code.class() == .informational) @compileError(std.fmt.comptimePrint(
        "http.status: {d} is an interim status, which does not answer a request; answer with a final status such as `.ok` or `.no_content`",
        .{@backingInt(code)},
    ));
    return struct {
        const sends_item = false;

        fn send(x: *Exchange, _: anytype) Exchange.Lost!void {
            _ = try x.begin(code, null, 0);
        }
    };
}

// ---------------------------------------------------------------------------
// Predicates and failures
// ---------------------------------------------------------------------------

fn requestOf(comptime who: []const u8, args: anytype) Request {
    if (comptime (args.len != 1 or @TypeOf(args[0]) != Request)) @compileError(
        who ++ ": tests an `http.Request`, got " ++ di.listTypes(di.types(@TypeOf(args))) ++
            "; use it in the pipe given to `http.serve(...)`, before the request is mapped to something else",
    );
    return args[0];
}

/// A predicate on the request's path, the target before its `?`. Given a
/// string, it holds when the path is exactly that. Given a predicate of
/// text, such as a pattern of `zrx.ext.pattern`, the path is put to it and
/// the answer is that predicate's: with one that finds a value, the case of
/// a `route` is given what it found, with the request. Text found in a path
/// points into the request's head, as the path itself does.
///
/// Taking either, the parameter has no type to give: an expression that
/// takes its type from where it stands names it, as in
/// `http.path(@as([]const u8, @ptrCast(&chars)))`.
pub fn path(comptime expected: anytype) type {
    if (comptime di.isHandler(expected)) return PathPut(expected);
    const Given = @TypeOf(expected);
    // What a `[]const u8` parameter took, which this was, as far as it has
    // a type of its own: a slice, a string literal, or a list of bytes
    // `&.{ '/', 'x' }`, whose elements the coercion below checks.
    const is_string = switch (@typeInfo(Given)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => di.isTuple(pointer.child),
            },
            else => false,
        },
        else => false,
    };
    if (!is_string) @compileError(
        "http.path: expected a string such as `\"/items\"`, or a predicate of text such as a pattern, got `" ++
            (if (Given == type) @typeName(expected) else @typeName(Given)) ++ "`",
    );
    const exact: []const u8 = expected;
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) bool {
            return std.mem.eql(u8, requestOf("http.path", args).path(), exact);
        }
    };
}

/// `path`, given a predicate of text: the request's path is put to it.
fn PathPut(comptime predicate: anytype) type {
    // Checks the predicate's shape where `http.path` is written, not where it is used.
    _ = di.requires("http.path", predicate, 1);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return di.requires("http.path", predicate, 1);
        }

        pub fn call(env: anytype, args: anytype) Answer(@TypeOf(env)) {
            return di.invoke(predicate, env, .{requestOf("http.path", args).path()});
        }

        /// What the predicate answers for a path: `bool`, or what it finds.
        fn Answer(comptime Env: type) type {
            @setEvalBranchQuota(di.quota);
            di.check("http.path", predicate, Env, &.{[]const u8});
            const R = di.Result("http.path", predicate, &.{[]const u8});
            _ = transform.Finds("http.path", R);
            return R;
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

/// Ends an error path in the pipe given to `serve`:
/// `recover(anyerror, .{http.fail()})` answers a request whose handling
/// failed with the status of its error (see `Error`; anything else is 500).
/// The connection goes on unless the request's body was left unread in a way
/// that hides where the next request begins. A broken connection is not
/// answered: its error passes on, for a `recover(http.Disconnected, ...)`
/// before `serve`.
pub fn fail() Responder("http.fail", Failure) {
    return .{};
}

const Failure = struct {
    const sends_item = false;

    fn send(x: *Exchange, failed: anytype) Exchange.Lost!void {
        const Item = @TypeOf(failed);
        if (comptime (@typeInfo(Item) != .@"struct" or !@hasField(Item, "err"))) @compileError(
            "http.fail: answers a failure, got `" ++ @typeName(Item) ++ "`; end the error path of a recover with it: `recover(anyerror, .{http.fail()})`",
        );
        const code: Status = switch (@as(anyerror, failed.err)) {
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
        _ = try x.begin(code, null, 0);
    }
};

/// What a connection that broke fails with. Before `serve`,
/// `recover(http.Disconnected, .{drain()})` drops such a connection and the
/// run goes on. Every other error still fails the run.
pub const Disconnected = error{ ReadFailed, WriteFailed };
