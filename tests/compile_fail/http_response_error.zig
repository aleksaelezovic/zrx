const zrx = @import("zrx");
test {
    const input = [_]error{Failed}!zrx.HttpResponse{error.Failed};
    _ = zrx.pipe(zrx.fromSlice(&input), .{zrx.respondHttp()});
}
