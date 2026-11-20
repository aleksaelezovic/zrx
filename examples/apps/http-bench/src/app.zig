//! The benchmark server: two endpoints over `zrx.ext.http`.
const std = @import("std");
const zrx = @import("zrx");
const http = zrx.ext.http;
const workers = @import("options").workers;

const pipe = zrx.pipe;
const program = zrx.program;
const system = zrx.system;
const fromProducer = zrx.fromProducer;
const map = zrx.map;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const recover = zrx.recover;
const drain = zrx.drain;
const concurrent = zrx.concurrent;
const print = zrx.print;
const all = zrx.all;
const any = zrx.any;
const constant = zrx.constant;

const Greeting = struct { message: []const u8 };
const greeting: Greeting = .{ .message = "Hello, World!" };

/// The integers of the query, plus the one in the body if there is one.
fn sum(request: http.Request) !i128 {
    var total: i128 = 0;
    var pairs = request.query();
    while (pairs.next()) |pair| total += std.fmt.parseInt(i64, pair.value, 10) catch 0;
    var buffer: [32]u8 = undefined;
    const body = std.mem.trim(u8, try request.body(&buffer), " \t\r\n");
    return total + (std.fmt.parseInt(i64, body, 10) catch 0);
}

const sums = pipe(.{
    map(sum),
    http.text("{d}"),
});

const greets = pipe(.{
    map(constant(greeting)),
    http.json(),
});

const isBaseline = http.path("/baseline11");
const isJson = http.path("/json");
const readsOrPosts = any(.{ http.method(.GET), http.method(.POST) });

/// What is done with a request.
pub const api = pipe(.{
    recover(anyerror, .{http.fail()}),
    route(.{
        when(all(.{ isBaseline, readsOrPosts }), sums),
        when(all(.{ isJson, http.method(.GET) }), greets),
        when(any(.{ isBaseline, isJson }), .{http.status(.method_not_allowed)}),
        otherwise(.{http.status(.not_found)}),
    }),
});

/// What is done with a connection: one of `workers` holds its conversation.
pub const server = program(http.connections(), .{
    concurrent(workers, .{
        recover(http.Disconnected, .{drain()}),
        http.serve(api),
    }),
});

/// The port the listener is bound to: the one the system chose when asked
/// for port 0.
fn boundPort(listener: http.Listener, out: anytype) !void {
    _ = try out.push(listener.port());
}

/// Tells whoever started the server which port it listens on.
pub const announcement = program(fromProducer(u16, boundPort), .{print(zrx.Stdout, "{d}\n")}).provide(.{zrx.stdout(16)});

/// Both share the listener: bound once, announced, and accepted from.
pub const service = system(.{ announcement, server });

/// What the service failed with. A run returns nothing; the command line
/// this server shares with the plain one wants the failure back.
const Failure = struct { err: ?anyerror = null };

fn noteFailure(failure: *Failure, err: anyerror) void {
    failure.err = err;
}

/// Serves on the loopback `port` (0 for one the system chooses) until it fails.
pub fn serve(io: std.Io, port: u16) !void {
    var failure: Failure = .{};
    service.run(.{
        io,
        &failure,
        zrx.rescue(noteFailure),
        http.listen(.{ .ip4 = .loopback(port) }, .{ .reuse_address = true }),
    });
    if (failure.err) |err| return err;
}
