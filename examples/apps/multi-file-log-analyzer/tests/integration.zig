const std = @import("std");
const app = @import("app");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn invoke(dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stdout: []const u8, stderr: []const u8) !void {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.appendSlice(allocator, args);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = expected_exit }, result.term);
    try std.testing.expectEqualStrings(stdout, result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
}

const left_text = "1\terror\tapi\t7\n3\twarn\tapi\t11\r\n5\terror\tapi\t13";
const right_text = "2\tinfo\tdb\t17\n4\terror\tdb\t19\n";
const left_alert_1 = "{\"source\":\"left\",\"ts_ms\":1,\"service\":\"api\",\"latency_ms\":7}";
const left_alert_2 = "{\"source\":\"left\",\"ts_ms\":5,\"service\":\"api\",\"latency_ms\":13}";
const right_alert = "{\"source\":\"right\",\"ts_ms\":4,\"service\":\"db\",\"latency_ms\":19}";
const summary = "{\"left\":{\"records\":3,\"warnings\":1,\"errors\":2,\"latency_ms\":31}," ++
    "\"right\":{\"records\":2,\"warnings\":0,\"errors\":1,\"latency_ms\":36}," ++
    "\"total\":{\"records\":5,\"warnings\":1,\"errors\":3,\"latency_ms\":67}}\n";

fn expectAlerts(text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const left = [_][]const u8{ left_alert_1, left_alert_2 };
    var n_left: usize = 0;
    var n_right: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) break;
        if (std.mem.eql(u8, line, right_alert)) {
            n_right += 1;
        } else {
            try std.testing.expect(n_left < left.len);
            try std.testing.expectEqualStrings(left[n_left], line);
            n_left += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), n_left);
    try std.testing.expectEqual(@as(usize, 1), n_right);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "injected streams preserve each source order and report one aggregate" {
    var left: std.Io.Reader = .fixed(left_text);
    var right: std.Io.Reader = .fixed(right_text);
    var storage: [2][512]u8 = undefined;
    var alerts: std.Io.Writer = .fixed(&storage[0]);
    var report: std.Io.Writer = .fixed(&storage[1]);
    try app.analyze(io, .{ .reader = &left }, .{ .reader = &right }, &alerts, &report);
    try expectAlerts(alerts.buffered());
    try std.testing.expectEqualStrings(summary, report.buffered());
}

test "the CLI writes one alerts file and reports totals after publication" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "left", .data = left_text });
    try temp.dir.writeFile(io, .{ .sub_path = "right", .data = right_text });
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 0, summary, "");
    const result = try temp.dir.readFileAlloc(io, "alerts", allocator, .limited(1024));
    defer allocator.free(result);
    try expectAlerts(result);
    try invoke(temp.dir, &.{ "left", "right", "left" }, 2, "", "fatal: PathAlreadyExists\n");
    const unchanged = try temp.dir.readFileAlloc(io, "left", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(left_text, unchanged);
}

test "malformed input leaves no published alerts or summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "left", .data = left_text });
    try temp.dir.writeFile(io, .{ .sub_path = "right", .data = "bad line\n" });
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 2, "", "fatal: InvalidLogRecord\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "alerts", .{}));
}
