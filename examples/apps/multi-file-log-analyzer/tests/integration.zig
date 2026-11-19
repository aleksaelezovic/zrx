const std = @import("std");
const app = @import("app");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

// The left log ends a line with CRLF and its last record has no newline.
const left_text = "1\terror\tapi\t7\n3\twarn\tapi\t11\r\n5\terror\tapi\t13";
const right_text = "2\tinfo\tdb\t17\n4\terror\tdb\t19\n6\terror\tcache\t23\n";

const left_alerts =
    \\{"source":"left","ts_ms":1,"service":"api","latency_ms":7}
    \\{"source":"left","ts_ms":5,"service":"api","latency_ms":13}
    \\
;
const right_alerts =
    \\{"source":"right","ts_ms":4,"service":"db","latency_ms":19}
    \\{"source":"right","ts_ms":6,"service":"cache","latency_ms":23}
    \\
;
const summary =
    \\{"left":{"records":3,"warnings":1,"errors":2,"latency_ms":31},"right":{"records":3,"warnings":0,"errors":2,"latency_ms":59}}
    \\
;

/// The alerts of each log are in that log's order. How the two logs
/// interleave is up to the run, so nothing here looks at it.
fn expectAlerts(text: []const u8) !void {
    try expectFrom("left", left_alerts, text);
    try expectFrom("right", right_alerts, text);
    try std.testing.expectEqual(left_alerts.len + right_alerts.len, text.len);
}

fn expectFrom(comptime side: []const u8, expected: []const u8, text: []const u8) !void {
    var own: std.ArrayList(u8) = .empty;
    defer own.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\"source\":\"" ++ side ++ "\"") == null) continue;
        try own.appendSlice(allocator, line);
        try own.append(allocator, '\n');
    }
    try std.testing.expectEqualStrings(expected, own.items);
}

// --- the app's program, with readers and writers of the test's own ----------

fn analyze(left_log: []const u8, right_log: []const u8, alerts: *std.Io.Writer, report: *std.Io.Writer) !void {
    var left: std.Io.Reader = .fixed(left_log);
    var right: std.Io.Reader = .fixed(right_log);
    try app.analyzer.run(.{
        io,
        app.Left{ .reader = &left },
        app.Right{ .reader = &right },
        app.Alerts{ .writer = alerts },
        app.Report{ .writer = report },
    });
}

test "failures keep the order of their log and the summary counts each log" {
    var storage: [2][512]u8 = undefined;
    var alerts: std.Io.Writer = .fixed(&storage[0]);
    var report: std.Io.Writer = .fixed(&storage[1]);
    try analyze(left_text, right_text, &alerts, &report);
    try expectAlerts(alerts.buffered());
    try std.testing.expectEqualStrings(summary, report.buffered());
}

test "empty logs give no alerts and a summary of zeros" {
    var storage: [2][512]u8 = undefined;
    var alerts: std.Io.Writer = .fixed(&storage[0]);
    var report: std.Io.Writer = .fixed(&storage[1]);
    try analyze("", "", &alerts, &report);
    try std.testing.expectEqualStrings("", alerts.buffered());
    try std.testing.expectEqualStrings(
        \\{"left":{"records":0,"warnings":0,"errors":0,"latency_ms":0},"right":{"records":0,"warnings":0,"errors":0,"latency_ms":0}}
        \\
    , report.buffered());
}

test "a malformed record fails the run before any summary" {
    for ([_][]const u8{ "bad line\n", "2\tinfo\tbad service\t17\n" }) |right_log| {
        var storage: [2][512]u8 = undefined;
        var alerts: std.Io.Writer = .fixed(&storage[0]);
        var report: std.Io.Writer = .fixed(&storage[1]);
        try std.testing.expectError(error.InvalidLogRecord, analyze(left_text, right_log, &alerts, &report));
        try std.testing.expectEqualStrings("", report.buffered());
    }
}

test "an alert that cannot be written fails the run" {
    var short: [1]u8 = undefined;
    var storage: [512]u8 = undefined;
    var alerts: std.Io.Writer = .fixed(&short);
    var report: std.Io.Writer = .fixed(&storage);
    // The summary is printed when the stream ends, whatever the alerts task
    // is doing by then: whether it got out is not looked at.
    try std.testing.expectError(error.WriteFailed, analyze(left_text, right_text, &alerts, &report));
}

// --- the executable ----------------------------------------------------------

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

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const text = try dir.readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
}

fn logs(dir: std.Io.Dir, left: []const u8, right: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "left", .data = left });
    try dir.writeFile(io, .{ .sub_path = "right", .data = right });
}

test "the executable publishes the alerts file and prints the summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try logs(temp.dir, left_text, right_text);
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 0, summary, "");
    const alerts = try temp.dir.readFileAlloc(io, "alerts", allocator, .limited(1024));
    defer allocator.free(alerts);
    try expectAlerts(alerts);
}

test "an existing alerts path is preserved, and the run fails after its summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try logs(temp.dir, left_text, right_text);
    try temp.dir.writeFile(io, .{ .sub_path = "alerts", .data = "kept\n" });
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 2, summary, "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "alerts", "kept\n");
    try invoke(temp.dir, &.{ "left", "right", "left" }, 2, summary, "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "left", left_text);
}

test "a malformed record publishes no alerts file and prints no summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try logs(temp.dir, left_text, "bad line\n");
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 2, "", "fatal: InvalidLogRecord\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.access(io, "alerts", .{}));
}

test "a missing log publishes no alerts file and prints no summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "left", .data = left_text });
    try invoke(temp.dir, &.{ "left", "right", "alerts" }, 2, "", "fatal: FileNotFound\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.access(io, "alerts", .{}));
}

test "anything but three paths is refused" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try invoke(temp.dir, &.{ "left", "right" }, 2, "", "fatal: InvalidArguments\n");
}
