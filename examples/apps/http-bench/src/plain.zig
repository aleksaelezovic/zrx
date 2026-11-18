const protocol = @import("protocol");

pub fn serve(server: *protocol.Server) !void {
    while (try protocol.next(server)) |value| {
        var request = value;
        if (protocol.isBaseline(&request)) {
            try protocol.baseline(&request);
        } else if (protocol.isJson(&request)) {
            try protocol.json(&request);
        } else {
            try protocol.notFound(&request);
        }
        if (!request.head.keep_alive) return;
    }
}
