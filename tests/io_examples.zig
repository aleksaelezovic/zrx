const std = @import("std");
const zrx = @import("zrx");
const cli = @import("io_cli");
const file = @import("io_file");
const tcp = @import("io_tcp");
const tcp_take = @import("io_tcp_take");
const Line = zrx.Line;
const line = zrx.line;
const writeFileLines = zrx.writeFileLines;
const Text = Line(256);
const allocator = std.testing.allocator;
const io = std.testing.io;

test "CLI graph routes commands and errors through independent terminals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try temporaryPath(&tmp, "stdout");
    defer allocator.free(output);
    const errors = try temporaryPath(&tmp, "stderr");
    defer allocator.free(errors);
    const input = [_]Text{
        try line(256, "ping"),
        try line(256, ""),
        try line(256, "upper Hello, Zig!"),
        try line(256, "unknown"),
    };
    try cli.execute(allocator, io, &input, writeFileLines(output, .{ .exclusive = true }), writeFileLines(errors, .{ .exclusive = true }));
    try expectFile(&tmp, "stdout", "pong\nHELLO, ZIG!\n");
    try expectFile(&tmp, "stderr", "error: expected ping or upper TEXT\n");
}

test "file program opens paths in run and extracts without hiding decisions in I/O" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try temporaryPath(&tmp, "input");
    defer allocator.free(input);
    const output = try temporaryPath(&tmp, "output");
    defer allocator.free(output);
    const errors = try temporaryPath(&tmp, "errors");
    defer allocator.free(errors);
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "keep first\nskip\nkeep last" });
    try file.execute(allocator, io, input, output, writeFileLines(errors, .{ .exclusive = true }));
    try expectFile(&tmp, "output", "first\nlast\n");
    try expectFile(&tmp, "errors", "skip\n");
}

test "network program shares decoding between display and file audit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try temporaryPath(&tmp, "display");
    defer allocator.free(output);
    const audit = try temporaryPath(&tmp, "audit");
    defer allocator.free(audit);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn send(listener: *std.Io.net.Server) !void {
            const connection = try listener.accept(io);
            defer connection.close(io);
            var buffer: [64]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("INFO ready\nWARN hot\nbad");
            try writer.interface.flush();
        }
    };
    var peer = try io.concurrent(Peer.send, .{&server});
    defer peer.cancel(io) catch {};
    try tcp.execute(allocator, io, server.socket.address, audit, writeFileLines(output, .{ .exclusive = true }));
    try peer.await(io);
    try expectFile(&tmp, "display", "INFO ready\nWARN hot\n");
    try expectFile(&tmp, "audit", "WARN hot\nbad\n");
}

test "TCP prefix capture finalizes both outputs and closes without peer EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try temporaryPath(&tmp, "display");
    defer allocator.free(output);
    const capture = try temporaryPath(&tmp, "capture");
    defer allocator.free(capture);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn send(listener: *std.Io.net.Server) !void {
            const connection = try listener.accept(io);
            defer connection.close(io);
            var buffer: [64]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("first\nsecond\n");
            try writer.interface.flush();
            // Do not close our sending half: wait for the completed client to
            // close. A client waiting for peer EOF would deadlock here.
            var reader = connection.reader(io, &buffer);
            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
        }
    };
    const Execution = struct {
        address: std.Io.net.IpAddress,
        capture: []const u8,
        output: []const u8,
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            try tcp_take.execute(allocator, io, self.address, 2, self.capture, writeFileLines(self.output, .{ .exclusive = true }));
        }
    };
    var peer = try io.concurrent(Peer.send, .{&server});
    defer peer.cancel(io) catch {};
    var execution: Execution = .{ .address = server.socket.address, .capture = capture, .output = output };
    var client = try io.concurrent(Execution.execute, .{&execution});
    defer client.cancel(io) catch {};
    try execution.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try client.await(io);
    try peer.await(io);
    try expectFile(&tmp, "display", "first\nsecond\n");
    try expectFile(&tmp, "capture", "first\nsecond\n");
}

// Fixture files remain inside the repository's Zig cache. Examples take only
// configuration/declarations; these helpers never supply open handles to them.
fn temporaryPath(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn expectFile(tmp: *std.testing.TmpDir, name: []const u8, expected: []const u8) !void {
    const bytes = try tmp.dir.readFileAlloc(io, name, allocator, .limited(4096));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
