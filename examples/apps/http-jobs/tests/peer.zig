const std = @import("std");
pub const allocator = std.testing.allocator;
pub const io = std.testing.io;
const watchdog: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

/// Bound the ENTIRE scenario, not each I/O individually. Cancellation joins the
/// task (and its deferred child/server cleanup) before borrowed state expires.
pub fn bounded(comptime function: anytype, args: anytype) !void {
    const Task = struct {
        args: @TypeOf(args),
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            @call(.auto, function, self.args) catch |err| {
                std.debug.print("bounded scenario failed: {s}\n", .{@errorName(err)});
                return err;
            };
        }
    };
    var task: Task = .{ .args = args };
    var future = try io.concurrent(Task.execute, .{&task});
    defer future.cancel(io) catch {};
    try task.done.waitTimeout(io, watchdog);
    try future.await(io);
}

pub fn exchange(address: std.Io.net.IpAddress, wire: []const u8) ![]u8 {
    return exchangeEnding(address, wire, false);
}

pub fn exchangeEnding(address: std.Io.net.IpAddress, wire: []const u8, close_send: bool) ![]u8 {
    const connection = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer connection.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.writeAll(wire);
    try writer.interface.flush();
    if (close_send) try connection.shutdown(io, .send);
    var read_buffer: [1024]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(4096));
}

pub fn post(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("POST /jobs HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body });
}

pub fn expectResponse(wire: []const u8, status: []const u8, body: []const u8) !void {
    const start = try std.fmt.allocPrint(allocator, "HTTP/1.1 {s}\r\n", .{status});
    defer allocator.free(start);
    if (!std.mem.startsWith(u8, wire, start)) {
        std.debug.print("expected {s}; actual response:\n{s}\n", .{ status, wire });
        return error.UnexpectedHttpStatus;
    }
    const delimiter = std.mem.find(u8, wire, "\r\n\r\n") orelse return error.MissingResponseHead;
    try std.testing.expectEqualStrings(body, wire[delimiter + 4 ..]);
    const headers = wire[0..delimiter];
    try contains(headers, "\r\ncontent-type: application/json");
    try contains(headers, "\r\ncache-control: no-store");
    const length = try std.fmt.allocPrint(allocator, "\r\ncontent-length: {d}", .{body.len});
    defer allocator.free(length);
    try contains(headers, length);
    try contains(headers, "\r\nconnection: close");
}

pub fn contains(bytes: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, bytes, expected) != null);
}

/// A connected socket can leave TIME_WAIT after correct cleanup, so immediate
/// rebind is not a valid release assertion. Closed admission must refuse peers.
pub fn expectClosed(address: std.Io.net.IpAddress) !void {
    const connection = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        try std.testing.expectEqual(error.ConnectionRefused, err);
        return;
    };
    connection.close(io);
    return error.ListenerStillOpen;
}

pub const valid = "{\"label\":\"total\",\"values\":[2,-3,5]}";
pub const recorded = "{\"id\":1,\"label\":\"total\",\"status\":\"completed\",\"result\":4}\n";
