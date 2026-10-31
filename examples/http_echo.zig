//! Opt-in serial loopback HTTP echo server. Usage: http-echo PORT [CONNECTIONS]
const std = @import("std");
const zrx = @import("zrx");
const httpRequests = zrx.httpRequests;
const respondHttp = zrx.respondHttp;
const pipe = zrx.pipe;
const each = zrx.each;
const run = zrx.run;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const Request = zrx.HttpRequest;
const Response = zrx.HttpResponse;
const Ready = zrx.HttpReady;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.ExpectedPortAndOptionalConnectionCount;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const count = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else null;
    var ready: Ready = .{};
    const Result = union(enum) { ready: std.Io.Cancelable!void, finished: anyerror!void };
    var buffer: [2]Result = undefined;
    var startup: std.Io.Select(Result) = .init(init.io, &buffer);
    defer startup.cancelDiscard();
    try startup.concurrent(.finished, execute, .{ init.gpa, init.io, zrx.HttpServerConfig{
        .address = .{ .ip4 = .loopback(port) },
        .connection_budget = count,
        .ready = &ready,
    } });
    try startup.concurrent(.ready, std.Io.Event.wait, .{ &ready.ready, init.io });
    switch (try startup.await()) {
        .finished => |result| return result,
        .ready => |result| try result,
    }
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.print("http://{f}\n", .{ready.address});
    try output.interface.flush();
    switch (try startup.await()) {
        .finished => |result| try result,
        .ready => unreachable,
    }
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, config: zrx.HttpServerConfig) !void {
    const server = pipe(httpRequests(config), .{
        branch(.{
            when(isHealth, each(healthResponse)),
            when(isEcho, each(echoResponse)),
            otherwise(each(notFoundResponse)),
        }),
        respondHttp(),
    });
    try run(.{ allocator, io }, .{server});
}

fn isHealth(request: Request) bool {
    return (request.method == .GET or request.method == .HEAD) and std.mem.eql(u8, request.target, "/health");
}

fn isEcho(request: Request) bool {
    return request.method == .POST and std.mem.eql(u8, request.target, "/echo");
}

pub fn healthResponse(request: Request) Response {
    return request.response(.{ .body = "ok\n" });
}

fn echoResponse(request: Request) Response {
    const body = request.readRemainingBody() catch |err| return request.response(.{
        .status = if (err == error.HttpBodyTooLarge) .payload_too_large else .bad_request,
        .body = "invalid body\n",
    });
    return request.response(.{ .body = body });
}

fn notFoundResponse(request: Request) Response {
    return request.response(.{ .status = .not_found, .body = "not found\n" });
}
