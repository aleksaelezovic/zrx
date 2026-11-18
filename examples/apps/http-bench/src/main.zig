const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol");
const app = @import("app");

const usage = "usage: http-bench serve PORT [WORKERS] | replay REQUEST_FILE\n";
const max_workers = 64;
const input_bytes = 8 * 1024;
const output_bytes = 4 * 1024;

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        var buffer: [256]u8 = undefined;
        var writer = Io.File.stderr().writerStreaming(init.io, &buffer);
        writer.interface.print("fatal: {s}\n{s}", .{ @errorName(err), usage }) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn execute(init: std.process.Init) !void {
    const args = (try init.minimal.args.toSlice(init.arena.allocator()))[1..];
    const io = init.io;
    var out_buffer: [output_bytes]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try out.interface.writeAll(usage);
        try out.interface.flush();
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "replay")) {
        const file = try Io.Dir.cwd().openFile(io, args[1], .{});
        defer file.close(io);
        var input_buffer: [input_bytes]u8 = undefined;
        var input = file.readerStreaming(io, &input_buffer);
        var server = protocol.Server.init(&input.interface, &out.interface);
        try app.serve(&server);
        return;
    }
    if (args.len < 2 or args.len > 3 or !std.mem.eql(u8, args[0], "serve"))
        return error.InvalidArguments;
    const port = std.fmt.parseInt(u16, args[1], 10) catch return error.InvalidPort;
    const workers = if (args.len == 3)
        std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidWorkerCount
    else
        8;
    if (workers == 0 or workers > max_workers) return error.InvalidWorkerCount;
    try listen(io, port, workers, &out.interface);
}

fn listen(io: Io, port: u16, count: usize, ready: *Io.Writer) !void {
    var listener = try (try Io.net.IpAddress.parse("127.0.0.1", port)).listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const Result = union(enum) { worker: @typeInfo(@TypeOf(worker)).@"fn".return_type.? };
    var slots: [max_workers]Result = undefined;
    var tasks = Io.Select(Result).init(io, slots[0..count]);
    defer tasks.cancelDiscard();
    for (0..count) |_| try tasks.concurrent(.worker, worker, .{ io, &listener });
    try ready.print("{d}\n", .{listener.socket.address.getPort()});
    try ready.flush();
    // Workers run until listening fails or this task is canceled.
    return (try tasks.await()).worker;
}

fn worker(io: Io, listener: *Io.net.Server) !void {
    while (true) {
        try io.checkCancel();
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        try serveConnection(io, stream);
    }
}

fn serveConnection(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);
    var input_buffer: [input_bytes]u8 = undefined;
    var output_buffer: [output_bytes]u8 = undefined;
    var input = stream.reader(io, &input_buffer);
    var output = stream.writer(io, &output_buffer);
    var server = protocol.Server.init(&input.interface, &output.interface);
    // Disconnects, malformed requests and failed writes affect this connection.
    app.serve(&server) catch {};
    // Reader/Writer surface cancellation as a failed read/write.
    if (input.err) |err| if (err == error.Canceled) return error.Canceled;
    if (output.err) |err| if (err == error.Canceled) return error.Canceled;
}
