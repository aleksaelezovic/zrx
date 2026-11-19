//! The same server written against `std` alone: what zrx is compared with.
//! Each worker accepts a connection, serves it to its end and accepts the
//! next; every response is flushed as `std.http.Server` does by default.
const std = @import("std");
const Io = std.Io;
const workers = @import("options").workers;

const Server = std.http.Server;
const Request = Server.Request;
const input_bytes = 8 * 1024;
const output_bytes = 4 * 1024;

/// Serves on the loopback `port` (0 for one the system chooses) until it fails.
pub fn listen(io: Io, port: u16) !void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const Result = union(enum) { worker: Io.net.Server.AcceptError!void };
    var slots: [workers]Result = undefined;
    var tasks = Io.Select(Result).init(io, &slots);
    defer tasks.cancelDiscard();
    for (0..workers) |_| try tasks.concurrent(.worker, worker, .{ io, &listener });

    var buffer: [16]u8 = undefined;
    var ready = Io.File.stdout().writerStreaming(io, &buffer);
    try ready.interface.print("{d}\n", .{listener.socket.address.getPort()});
    try ready.interface.flush();
    // Workers run until listening fails or this task is canceled.
    return (try tasks.await()).worker;
}

fn worker(io: Io, listener: *Io.net.Server) Io.net.Server.AcceptError!void {
    while (true) {
        try io.checkCancel();
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        try serveConnection(io, stream);
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    var input_buffer: [input_bytes]u8 = undefined;
    var output_buffer: [output_bytes]u8 = undefined;
    var input = stream.reader(io, &input_buffer);
    var output = stream.writer(io, &output_buffer);
    var server = Server.init(&input.interface, &output.interface);
    // Disconnects, malformed requests and failed writes affect this connection.
    serve(&server) catch {};
    // Reader/Writer surface cancellation as a failed read/write.
    if (input.err) |err| if (err == error.Canceled) return error.Canceled;
    if (output.err) |err| if (err == error.Canceled) return error.Canceled;
}

/// The conversation on one connection.
pub fn serve(server: *Server) !void {
    while (try next(server)) |value| {
        var request = value;
        if (request.head.transfer_encoding != .none) {
            // Chunked bodies are not read, as in the zrx server.
            try reject(&request, if (request.head.content_length != null) .bad_request else .length_required);
        } else if (isPath(&request, "/baseline11")) {
            try baseline(&request);
        } else if (isPath(&request, "/json")) {
            try json(&request);
        } else {
            try reject(&request, .not_found);
        }
        if (!request.head.keep_alive) return;
    }
}

fn next(server: *Server) !?Request {
    if (server.reader.state != .ready) return null;
    return server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => null,
        else => return err,
    };
}

fn isPath(request: *const Request, path: []const u8) bool {
    const target = request.head.target;
    return std.mem.eql(u8, target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len], path);
}

fn reply(request: *Request, content_type: []const u8, text: []const u8) !void {
    try request.respond(text, .{
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}

fn reject(request: *Request, status: std.http.Status) !void {
    request.head.keep_alive = false;
    request.head.expect = null;
    try request.respond("", .{ .status = status, .keep_alive = false });
}

fn hasBody(request: *const Request) bool {
    return (request.head.content_length orelse 0) != 0;
}

fn querySum(target: []const u8) i128 {
    const start = std.mem.findScalar(u8, target, '?') orelse return 0;
    var pairs = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    var sum: i128 = 0;
    while (pairs.next()) |pair| {
        const separator = std.mem.findScalar(u8, pair, '=') orelse continue;
        // The profile sends decimal integer values in an ASCII query.
        const value = std.fmt.parseInt(i64, pair[separator + 1 ..], 10) catch continue;
        sum += value;
    }
    return sum;
}

fn baseline(request: *Request) !void {
    var sum = querySum(request.head.target);
    switch (request.head.method) {
        .GET => if (hasBody(request)) return reject(request, .bad_request),
        .POST => {
            const length = request.head.content_length orelse return reject(request, .length_required);
            if (length > 32) return reject(request, .payload_too_large);
            var body: [32]u8 = undefined;
            const reader = request.readerExpectContinue(&.{}) catch |err| switch (err) {
                error.HttpExpectationFailed => return reject(request, .expectation_failed),
                error.WriteFailed => return err,
            };
            const n = try reader.readSliceShort(&body);
            const text = std.mem.trim(u8, body[0..n], " \r\n\t");
            if (text.len != 0) sum += std.fmt.parseInt(i64, text, 10) catch 0;
        },
        else => return reject(request, .method_not_allowed),
    }
    var response: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&response, "{d}", .{sum});
    try reply(request, "text/plain", text);
}

fn json(request: *Request) !void {
    if (request.head.method != .GET) return reject(request, .method_not_allowed);
    if (hasBody(request)) return reject(request, .bad_request);
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .message = "Hello, World!" }, .{}, &writer);
    try reply(request, "application/json", writer.buffered());
}
