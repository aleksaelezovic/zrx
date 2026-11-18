const zrx = @import("zrx");
const protocol = @import("protocol");
const forEach = zrx.forEach;
const when = zrx.when;
const otherwise = zrx.otherwise;
const route = zrx.route;

const Connection = struct { server: *protocol.Server };

fn requests(connection: Connection, out: anytype) !void {
    while (try protocol.next(connection.server)) |value| {
        // The head's strings borrow the connection reader. The synchronous
        // push completes before receiving another head.
        var request = value;
        if (try out.push(&request) == .done or !request.head.keep_alive) return;
    }
}

const sum = zrx.pipe(.{forEach(protocol.baseline)});
const json = zrx.pipe(.{forEach(protocol.json)});
const missing = zrx.pipe(.{forEach(protocol.notFound)});
const app = zrx.program(zrx.fromProducer(*protocol.Request, requests), .{
    route(.{
        when(protocol.isBaseline, sum),
        when(protocol.isJson, json),
        otherwise(missing),
    }),
});

pub fn serve(server: *protocol.Server) !void {
    try app.run(.{Connection{ .server = server }});
}
