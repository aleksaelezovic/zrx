const std = @import("std");
const zrx = @import("zrx");
const httpRequests = zrx.httpRequests;
const respondHttp = zrx.respondHttp;
const each = zrx.each;
const pipe = zrx.pipe;
const run = zrx.run;
const branch = zrx.branch;
const otherwise = zrx.otherwise;

fn handle(request: zrx.HttpRequest) zrx.HttpResponse {
    const body = request.readRemainingBody() catch return request.response(.{ .status = .bad_request });
    return request.response(.{ .body = body });
}

export fn http_server(allocator: *const std.mem.Allocator, io: *const std.Io, port: u16) bool {
    const incoming = httpRequests(zrx.HttpServerConfig{ .address = .{ .ip4 = .loopback(port) }, .connection_budget = 1 });
    const responses = pipe(&incoming, .{branch(.{otherwise(each(handle))})});
    run(.{ allocator.*, io.* }, .{pipe(&responses, .{respondHttp()})}) catch return false;
    return true;
}

const Config = struct { port: u16, starts: *usize, ends: *usize };
fn configure(config: Config) zrx.HttpServerConfig {
    return .{ .address = .{ .ip4 = .loopback(config.port) }, .connection_budget = 0 };
}
const ReadyServer = struct { server: *zrx.HttpServer };
fn announced(server: *zrx.HttpServer, config: Config, _: void) ReadyServer {
    config.starts.* += 1;
    return .{ .server = server };
}
export fn http_configured(allocator: *const std.mem.Allocator, io: *const std.Io, port: u16, starts: *usize, ends: *usize) bool {
    const program = pipe(httpRequests(ReadyServer), .{
        each(handle), respondHttp(),
    });
    run(.{
        allocator.*, io.*, Config{ .port = port, .starts = starts, .ends = ends }, zrx.httpServer(configure), zrx.resource({}, announced, null),
    }, .{program}) catch return false;
    ends.* += 1;
    return true;
}

fn jsonHandle(request: zrx.HttpRequest) !zrx.HttpResponse {
    const header = request.uniqueHeader("x-name") catch
        return request.jsonResponse(.{ .@"error" = "duplicate" }, .{ .status = .bad_request });
    var values = request.headerValues("x-tag");
    var count: usize = 0;
    while (values.next() != null) count += 1;
    _ = request.readRemainingBody() catch |err| switch (err) {
        error.HttpBodyTooLarge, error.HttpInvalidBody => return request.jsonResponse(.{ .@"error" = @errorName(err) }, .{ .status = .bad_request }),
        else => return err,
    };
    return request.jsonResponse(.{ .name = header, .tags = count }, .{});
}

export fn http_json_helpers(allocator: *const std.mem.Allocator, io: *const std.Io, port: u16, connections: usize) bool {
    const flow = pipe(httpRequests(zrx.HttpServerConfig{
        .address = .{ .ip4 = .loopback(port) },
        .connection_budget = connections,
    }), .{ each(jsonHandle), respondHttp() });
    run(.{ allocator.*, io.* }, .{flow}) catch return false;
    return true;
}

const RoutePolicy = struct { method: std.http.Method };
fn permitted(policy: RoutePolicy, request: zrx.HttpRequest) bool {
    return request.method == policy.method;
}
export fn http_predicate_routes(allocator: *const std.mem.Allocator, io: *const std.Io, port: u16, connections: usize, method_code: u8) bool {
    const program = pipe(httpRequests(zrx.HttpServerConfig{
        .address = .{ .ip4 = .loopback(port) },
        .connection_budget = connections,
    }), .{
        branch(.{
            zrx.when(zrx.all(.{ permitted, zrx.httpPathPrefix("/jobs/") }), each(jsonHandle)),
            zrx.when(zrx.any(.{ zrx.httpMethod(.GET), zrx.httpTarget("*") }), each(handle)),
            otherwise(each(handle)),
        }),
        respondHttp(),
    });
    run(.{
        allocator.*, io.*, RoutePolicy{ .method = if (method_code == 0) .GET else .POST },
    }, .{program}) catch return false;
    return true;
}
