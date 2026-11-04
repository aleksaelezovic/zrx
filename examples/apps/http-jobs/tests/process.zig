const std = @import("std");
const peer = @import("peer.zig");
const allocator = peer.allocator;
const io = peer.io;
const executable = @import("options").executable;

test "finite executable serves actual clients reports completion and exits cleanly" {
    try peer.bounded(processScenario, .{});
}

fn processScenario() !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, "serve", "0", "4", "1", "128", "3" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var stdout_buffer: [512]u8 = undefined;
    var stdout = child.stdout.?.readerStreaming(io, &stdout_buffer);
    // Readiness is an actual flushed protocol line, never a sleep/retry loop.
    const line = try stdout.interface.takeDelimiterExclusive('\n');
    stdout.interface.toss(1);
    const prefix = "ready http://";
    try std.testing.expect(std.mem.startsWith(u8, line, prefix));
    const address = try std.Io.net.IpAddress.parseLiteral(line[prefix.len..]);
    try std.testing.expect(address.getPort() != 0);
    const submitted = try peer.exchange(address, peer.post(peer.valid));
    defer allocator.free(submitted);
    try peer.expectResponse(submitted, "201 Created", peer.recorded);
    try peer.contains(submitted, "\r\nlocation: /jobs/1\r\n");
    const queried = try peer.exchange(address, "GET /jobs/1 HTTP/1.1\r\n\r\n");
    defer allocator.free(queried);
    try peer.expectResponse(queried, "200 OK", peer.recorded);
    const invalid = try peer.exchange(address, peer.post("{}"));
    defer allocator.free(invalid);
    try peer.expectResponse(invalid, "400 Bad Request", "{\"error\":\"invalid_job\"}\n");
    const full = try peer.exchange(address, peer.post(peer.valid));
    defer allocator.free(full);
    try peer.expectResponse(full, "503 Service Unavailable", "{\"error\":\"store_full\"}\n");
    const completion = try stdout.interface.takeDelimiterExclusive('\n');
    stdout.interface.toss(1);
    try std.testing.expectEqualStrings("stopped", completion);
    // Completion is reported AFTER run returns, not before listener cleanup.
    try peer.expectClosed(address);
    const rest = try stdout.interface.allocRemaining(allocator, .limited(1024));
    defer allocator.free(rest);
    try std.testing.expectEqualStrings("", rest);
    var stderr_buffer: [512]u8 = undefined;
    var stderr = child.stderr.?.readerStreaming(io, &stderr_buffer);
    const errors = try stderr.interface.allocRemaining(allocator, .limited(1024));
    defer allocator.free(errors);
    try std.testing.expectEqualStrings("", errors);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try peer.expectClosed(address);
}

test "executable rejects invalid configuration with exact stderr and exit status" {
    try peer.bounded(invalidScenario, .{});
}

test "zero-connection executable acquires releases and terminates without a client" {
    try peer.bounded(zeroScenario, .{});
}

fn zeroScenario() !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "serve", "0", "0" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    const line = lines.next() orelse return error.MissingReadiness;
    const prefix = "ready http://";
    try std.testing.expect(std.mem.startsWith(u8, line, prefix));
    const address = try std.Io.net.IpAddress.parseLiteral(line[prefix.len..]);
    try std.testing.expect(address.getPort() != 0);
    try std.testing.expectEqualStrings("stopped", lines.next().?);
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
    try peer.expectClosed(address);
}

fn invalidScenario() !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "serve", "0", "1", "0" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("http-jobs: InvalidLimits\n", result.stderr);
}
