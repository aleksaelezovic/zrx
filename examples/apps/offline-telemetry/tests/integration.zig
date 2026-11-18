const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn invoke(dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stdout: []const []const u8, stderr: []const u8) !void {
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
    try expectOutput(result.stdout, stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
}

const north_input = "1,-1\n2,3500\n";
const south_input = "3,8000\r\n4,8001";
const alerts = [_][]const u8{
    "{\"kind\":\"alert\",\"sensor\":\"north\",\"ts_ms\":1,\"temp_mc\":-1}",
    "{\"kind\":\"alert\",\"sensor\":\"south\",\"ts_ms\":4,\"temp_mc\":8001}",
};
const windows = [_][]const u8{
    "{\"kind\":\"window\",\"sensor\":\"north\",\"first_ts_ms\":2,\"last_ts_ms\":2,\"count\":1,\"min_mc\":3500,\"max_mc\":3500,\"sum_mc\":3500}",
    "{\"kind\":\"window\",\"sensor\":\"south\",\"first_ts_ms\":3,\"last_ts_ms\":3,\"count\":1,\"min_mc\":8000,\"max_mc\":8000,\"sum_mc\":8000}",
};

fn expectOutput(actual: []const u8, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, actual, '\n');
    var seen: [2]bool = @splat(false);
    try std.testing.expect(expected.len <= seen.len);
    for (0..expected.len) |_| {
        const text = lines.next() orelse return error.MissingRecord;
        for (expected, 0..) |want, i| {
            if (std.mem.eql(u8, text, want)) {
                try std.testing.expect(!seen[i]);
                seen[i] = true;
                break;
            }
        } else return error.UnexpectedRecord;
    }
    try std.testing.expectEqualStrings("", lines.next() orelse return error.MissingNewline);
    try std.testing.expectEqual(null, lines.next());
}

test "two injected inputs publish independent alerts and EOF windows" {
    var north: std.Io.Reader = .fixed(north_input);
    var south: std.Io.Reader = .fixed(south_input);
    var windows_buffer: [512]u8 = undefined;
    var alerts_buffer: [512]u8 = undefined;
    var archive: std.Io.Writer = .fixed(&windows_buffer);
    var alarms: std.Io.Writer = .fixed(&alerts_buffer);
    try app.process(io, .{ .reader = &north }, .{ .reader = &south }, &archive, &alarms);
    try expectOutput(archive.buffered(), &windows);
    try expectOutput(alarms.buffered(), &alerts);
}

// This producer cannot reach EOF until the one-item window has been flushed.
// A size-only batch or a flush at EOF cannot make this test pass.
const Idle = struct {
    writer: std.Io.Writer,
    flushed: std.Io.Event = .unset,
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Idle = @fieldParentPtr("writer", w);
        const payload = w.buffered();
        if (payload.len > self.bytes.len - self.len) return error.WriteFailed;
        @memcpy(self.bytes[self.len..][0..payload.len], payload);
        self.len += payload.len;
        w.end = 0;
        self.flushed.set(io);
    }

    fn produce(self: *Idle, out: anytype) !void {
        const text = "2,3500";
        var line: app.Line = .{ .bytes = undefined, .len = text.len };
        @memcpy(line.bytes[0..text.len], text);
        if (try out.push(line) == .done) return;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
        const deadline = timeout.toDeadline(io);
        while (!self.flushed.isSet()) {
            self.flushed.waitTimeout(io, deadline) catch |err| switch (err) {
                error.Timeout => if (deadline.deadline.durationFromNow(io).raw.nanoseconds <= 0)
                    return error.WindowDidNotFlush,
                else => return err,
            };
        }
    }
};

test "a partial window flushes while its producer is still idle" {
    var scratch: [256]u8 = undefined;
    var idle: Idle = .{ .writer = .{ .buffer = &scratch, .vtable = &.{
        .drain = std.Io.Writer.fixedDrain,
        .flush = Idle.flush,
    } } };
    var archive: app.Destination = .{ .writer = &idle.writer };
    var empty: std.Io.Writer = .fixed(&.{});
    var alarm: app.Destination = .{ .writer = &empty };
    const program = app.feedProgram(zrx.fromProducer(app.Line, Idle.produce), .north);
    try program.run(.{ io, app.Windows{ .output = &archive }, app.Alerts{ .output = &alarm }, &idle });
    try std.testing.expectEqualStrings(windows[0] ++ "\n", idle.bytes[0..idle.len]);
}

test "the executable publishes both feeds and refuses to replace an existing file" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "north", .data = north_input });
    try temp.dir.writeFile(io, .{ .sub_path = "south", .data = south_input });
    try invoke(temp.dir, &.{ "north", "south", "output" }, 0, &alerts, "");
    const actual = try temp.dir.readFileAlloc(io, "output", allocator, .limited(1024));
    defer allocator.free(actual);
    try expectOutput(actual, &windows);
    try invoke(temp.dir, &.{ "north", "south", "output" }, 2, &alerts, "fatal: PathAlreadyExists\n");
}

test "invalid input fails without publishing the windows file" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "north", .data = "2,3500\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "south", .data = "bad\n" });
    try invoke(temp.dir, &.{ "north", "south", "output" }, 2, &.{}, "fatal: InvalidReading\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "output", .{}));
}

test "routine readings are summarized once across consecutive windows" {
    var north: std.Io.Reader = .fixed("1,1000\n2,2000\n3,3000\n4,4000\n5,5000\n6,6000\n7,7000\n8,8000\n9,0\n");
    var south: std.Io.Reader = .fixed("");
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var no_alerts: std.Io.Writer = .fixed(&.{});
    try app.process(io, .{ .reader = &north }, .{ .reader = &south }, &writer, &no_alerts);

    const Window = struct {
        kind: []const u8,
        sensor: app.Sensor,
        first_ts_ms: usize,
        last_ts_ms: usize,
        count: usize,
        min_mc: i32,
        max_mc: i32,
        sum_mc: i32,
    };
    const temperatures = [_]i32{ 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 0 };
    var next: usize = 1;
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) break;
        const parsed = try std.json.parseFromSlice(Window, allocator, line, .{});
        defer parsed.deinit();
        const window = parsed.value;
        try std.testing.expectEqualStrings("window", window.kind);
        try std.testing.expectEqual(app.Sensor.north, window.sensor);
        try std.testing.expect(window.count >= 1 and window.count <= app.batch_size);
        try std.testing.expectEqual(next, window.first_ts_ms);
        try std.testing.expectEqual(next + window.count - 1, window.last_ts_ms);
        try std.testing.expect(window.last_ts_ms <= temperatures.len);
        const values = temperatures[window.first_ts_ms - 1 .. window.last_ts_ms];
        try std.testing.expectEqual(std.mem.min(i32, values), window.min_mc);
        try std.testing.expectEqual(std.mem.max(i32, values), window.max_mc);
        var sum: i32 = 0;
        for (values) |value| sum += value;
        try std.testing.expectEqual(sum, window.sum_mc);
        next = window.last_ts_ms + 1;
    }
    try std.testing.expectEqual(temperatures.len + 1, next);
}
