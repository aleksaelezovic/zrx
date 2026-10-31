const zrx = @import("zrx");
test {
    const source = zrx.httpRequests(.{ .address = .{ .ip4 = .loopback(0) } });
    _ = zrx.pipe(&source, .{zrx.each(handle)}).iterator();
}

fn handle(request: zrx.HttpRequest) zrx.HttpResponse {
    return request.response(.{});
}
