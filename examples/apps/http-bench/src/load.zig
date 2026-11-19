//! A load generator that can pipeline, which `hey` cannot:
//!
//!     http-bench-load PORT CONNECTIONS DEPTH BATCHES PATH BODY
//!
//! Opens CONNECTIONS connections, then on each sends BATCHES times DEPTH
//! `GET PATH` requests in one write and reads DEPTH answers. Every answer
//! must be a 200 with BODY and as long as the first one, whatever headers
//! the server adds. Prints the requests answered per second and the 99th
//! percentile of the time a batch took, in milliseconds.
const std = @import("std");
const Io = std.Io;

const ok = "HTTP/1.1 200";

const Load = struct {
    io: Io,
    depth: usize,
    request: []const u8,
    body: []const u8,
    /// The length of one answer, learned from the first.
    answer_len: usize = 0,

    /// Sends one request and measures its answer.
    fn probe(load: *Load, stream: Io.net.Stream) !void {
        var buffer: [16 * 1024]u8 = undefined;
        var out = stream.writer(load.io, &.{});
        var in = stream.reader(load.io, &buffer);
        try out.interface.writeAll(load.request);
        const head_len = while (true) {
            if (std.mem.find(u8, in.interface.buffered(), "\r\n\r\n")) |end| break end + 4;
            try in.interface.fillMore();
        };
        load.answer_len = head_len + load.body.len;
        try load.expect(try in.interface.take(load.answer_len));
    }

    fn expect(load: *const Load, answer: []const u8) !void {
        if (!std.mem.startsWith(u8, answer, ok) or !std.mem.endsWith(u8, answer, load.body)) return error.UnexpectedAnswer;
    }
};

const Client = struct {
    load: *const Load,
    stream: Io.net.Stream,
    /// How long each batch took, in nanoseconds.
    batches: []u64,
    failure: ?anyerror = null,

    fn run(client: *Client) void {
        client.converse() catch |err| {
            client.failure = err;
        };
    }

    fn converse(client: *Client) !void {
        const load = client.load;
        var out_buffer: [64 * 1024]u8 = undefined;
        var in_buffer: [64 * 1024]u8 = undefined;
        var out = client.stream.writer(load.io, &out_buffer);
        var in = client.stream.reader(load.io, &in_buffer);
        for (client.batches) |*took| {
            const start = Io.Timestamp.now(load.io, .awake);
            for (0..load.depth) |_| try out.interface.writeAll(load.request);
            try out.interface.flush();
            for (0..load.depth) |_| try load.expect(try in.interface.take(load.answer_len));
            took.* = @intCast(start.untilNow(load.io, .awake).toNanoseconds());
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) return error.InvalidArguments;
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(try std.fmt.parseInt(u16, args[1], 10)) };
    const batches = try std.fmt.parseInt(usize, args[4], 10);
    var load: Load = .{
        .io = io,
        .depth = try std.fmt.parseInt(usize, args[3], 10),
        .request = try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{args[5]}),
        .body = args[6],
    };

    // Connect one after another, before the clock starts: a server's
    // backlog is not what is measured.
    const clients = try arena.alloc(Client, try std.fmt.parseInt(usize, args[2], 10));
    const took = try arena.alloc(u64, clients.len * batches);
    for (clients, 0..) |*client, i| {
        client.* = .{ .load = &load, .stream = try address.connect(io, .{ .mode = .stream }), .batches = took[i * batches ..][0..batches] };
        if (i == 0) try load.probe(client.stream);
    }
    defer for (clients) |client| client.stream.close(io);

    const threads = try arena.alloc(std.Thread, clients.len);
    const start = Io.Timestamp.now(io, .awake);
    for (threads, clients) |*thread, *client| thread.* = try std.Thread.spawn(.{}, Client.run, .{client});
    for (threads) |thread| thread.join();
    const seconds = @as(f64, @floatFromInt(start.untilNow(io, .awake).toNanoseconds())) / std.time.ns_per_s;
    for (clients) |client| if (client.failure) |err| return err;

    std.mem.sortUnstable(u64, took, {}, std.sort.asc(u64));
    const p99 = @as(f64, @floatFromInt(took[took.len * 99 / 100])) / std.time.ns_per_ms;
    const requests: f64 = @floatFromInt(took.len * load.depth);
    var buffer: [64]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("{d:.0} {d:.3}\n", .{ requests / seconds, p99 });
    try stdout.interface.flush();
}
