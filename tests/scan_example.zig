const std = @import("std");
const zrx = @import("zrx");
const monitor = @import("scan_example");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;

test "transfer monitor renders every accumulated update and answers two requests" {
    const Fixture = struct {
        fn chunks(output: *Emitter(monitor.Chunk)) !void {
            for ([_]u32{ 3, 5, 0 }) |bytes| try output.push(.{ .bytes = bytes });
        }
        fn requests(output: *Emitter(u32)) !void {
            try output.push(1);
            try output.push(2);
        }
    };
    var progress_buffer: [256]u8 = undefined;
    var report_buffer: [256]u8 = undefined;
    var dashboard: std.Io.Writer = .fixed(&progress_buffer);
    var replies: std.Io.Writer = .fixed(&report_buffer);
    const chunks = Stream(monitor.Chunk).fromProducer(1, Fixture.chunks);
    const requests = Stream(u32).fromProducer(1, Fixture.requests);
    try monitor.monitor(.{ std.testing.allocator, std.testing.io, monitor.Dashboard{ .writer = &dashboard }, monitor.Reports{ .writer = &replies } }, &chunks, &requests);
    try std.testing.expectEqualStrings(
        "0 chunks, 0 bytes\n1 chunks, 3 bytes\n2 chunks, 8 bytes\n3 chunks, 8 bytes\n",
        dashboard.buffered(),
    );
    var lines = std.mem.splitScalar(u8, replies.buffered(), '\n');
    for ([_][]const u8{ "request 1: ", "request 2: " }) |prefix| {
        const line = lines.next().?;
        try std.testing.expect(std.mem.startsWith(u8, line, prefix));
        const value = line[prefix.len..];
        try std.testing.expect(
            std.mem.eql(u8, value, "0 bytes") or
                std.mem.eql(u8, value, "3 bytes") or
                std.mem.eql(u8, value, "8 bytes"),
        );
    }
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expectEqual(null, lines.next());
}
