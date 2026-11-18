const std = @import("std");
const Io = std.Io;

pub const Server = std.http.Server;
pub const Request = Server.Request;

pub fn next(server: *Server) !?Request {
    if (server.reader.state != .ready) return null;
    return server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => null,
        else => return err,
    };
}

fn path(request: *const Request) []const u8 {
    const target = request.head.target;
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

pub fn isBaseline(request: *Request) bool {
    return std.mem.eql(u8, path(request), "/baseline11");
}

pub fn isJson(request: *Request) bool {
    return std.mem.eql(u8, path(request), "/json");
}

fn reply(request: *Request, status: std.http.Status, content_type: []const u8, text: []const u8) !void {
    try request.respond(text, .{
        .status = status,
        .keep_alive = request.head.keep_alive,
        .extra_headers = &.{.{ .name = "content-type", .value = content_type }},
    });
}

fn reject(request: *Request, status: std.http.Status, text: []const u8) !void {
    request.head.keep_alive = false;
    request.head.expect = null;
    try reply(request, status, "text/plain", text);
}

fn hasBody(request: *const Request) bool {
    return request.head.transfer_encoding != .none or (request.head.content_length orelse 0) != 0;
}

fn querySum(target: []const u8) i128 {
    const start = std.mem.indexOfScalar(u8, target, '?') orelse return 0;
    var pairs = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    var sum: i128 = 0;
    while (pairs.next()) |pair| {
        const separator = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        // The profile sends decimal integer values in an ASCII query.
        const value = std.fmt.parseInt(i64, pair[separator + 1 ..], 10) catch continue;
        sum += value;
    }
    return sum;
}

pub fn baseline(request: *Request) !void {
    var sum = querySum(request.head.target);
    switch (request.head.method) {
        .GET => if (hasBody(request)) return reject(request, .bad_request, "unexpected body"),
        .POST => {
            if (request.head.transfer_encoding == .none and request.head.content_length == null)
                return reject(request, .length_required, "body framing required");
            if (request.head.content_length) |n| {
                if (n > 32) return reject(request, .payload_too_large, "body too large");
                if (request.head.transfer_encoding != .none)
                    return reject(request, .bad_request, "ambiguous body framing");
            }
            var body_buffer: [32]u8 = undefined;
            var body: [33]u8 = undefined;
            const reader = request.readerExpectContinue(&body_buffer) catch |err| switch (err) {
                error.HttpExpectationFailed => return reject(request, .expectation_failed, "unsupported expectation"),
                error.WriteFailed => return err,
            };
            const n = try reader.readSliceShort(&body);
            if (n == body.len) return reject(request, .payload_too_large, "body too large");
            const text = std.mem.trim(u8, body[0..n], " \r\n\t");
            if (text.len != 0) sum += std.fmt.parseInt(i64, text, 10) catch 0;
        },
        else => return reject(request, .method_not_allowed, "method not allowed"),
    }
    var response: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&response, "{d}", .{sum});
    try reply(request, .ok, "text/plain", text);
}

pub fn json(request: *Request) !void {
    if (request.head.method != .GET) return reject(request, .method_not_allowed, "method not allowed");
    if (hasBody(request)) return reject(request, .bad_request, "unexpected body");
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .message = "Hello, World!" }, .{}, &writer);
    try reply(request, .ok, "application/json", writer.buffered());
}

pub fn notFound(request: *Request) !void {
    try reject(request, .not_found, "not found");
}
