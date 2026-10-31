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
    const incoming = httpRequests(.{ .address = .{ .ip4 = .loopback(port) }, .connection_budget = 1 });
    const responses = pipe(&incoming, .{branch(.{otherwise(each(handle))})});
    run(.{ allocator.*, io.* }, .{pipe(&responses, .{respondHttp()})}) catch return false;
    return true;
}
