const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

const Clock = zrx.testing.Clock;

const north_input = "1,-1\n2,3500\n";
const south_input = "3,8000\r\n4,8001";
const north_alert = "{\"sensor\":\"north\",\"ts_ms\":1,\"temp_mc\":-1}\n";
const south_alert = "{\"sensor\":\"south\",\"ts_ms\":4,\"temp_mc\":8001}\n";
const north_window = "{\"first_ts_ms\":2,\"last_ts_ms\":2,\"count\":1,\"min_mc\":3500,\"max_mc\":3500,\"sum_mc\":3500}\n";
const south_window = "{\"first_ts_ms\":3,\"last_ts_ms\":3,\"count\":1,\"min_mc\":8000,\"max_mc\":8000,\"sum_mc\":8000}\n";

/// What one feed wrote. Feeds run at the same time, so each has its own.
const Log = struct {
    archive: std.Io.Writer,
    alerts: std.Io.Writer,

    fn init(archive: []u8, alerts: []u8) Log {
        return .{ .archive = .fixed(archive), .alerts = .fixed(alerts) };
    }
};

/// The production program over one feed's text, written to `log`. Its clock
/// stands still, so only a full window or the end of input closes a window.
fn replay(sensor: app.Sensor, input: []const u8, log: *Log) !void {
    var clock: Clock = .init(io);
    var reader: std.Io.Reader = .fixed(input);
    try tryRun(app.feed, .{
        clock.io(),
        sensor,
        app.Input{ .reader = &reader },
        app.Archive{ .writer = &log.archive },
        app.Alerts{ .writer = &log.alerts },
    });
}

test "a feed prints its alerts and archives full windows and the one left at the end of input" {
    var buffers: [2][512]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    // 0 and 8000 are routine. The alert at 5 does not end the window around it.
    try replay(.south, "1,1000\n2,2000\n3,3000\n4,4000\n5,8001\n6,5000\n7,6000\n8,7000\n9,8000\n10,0\r\n11,-1", &log);
    try std.testing.expectEqualStrings(
        "{\"sensor\":\"south\",\"ts_ms\":5,\"temp_mc\":8001}\n" ++
            "{\"sensor\":\"south\",\"ts_ms\":11,\"temp_mc\":-1}\n",
        log.alerts.buffered(),
    );
    try std.testing.expectEqualStrings(
        "{\"first_ts_ms\":1,\"last_ts_ms\":9,\"count\":8,\"min_mc\":1000,\"max_mc\":8000,\"sum_mc\":36000}\n" ++
            "{\"first_ts_ms\":10,\"last_ts_ms\":10,\"count\":1,\"min_mc\":0,\"max_mc\":0,\"sum_mc\":0}\n",
        log.archive.buffered(),
    );
}

test "two feeds of a system write only to their own archive and alerts" {
    var clock: Clock = .init(io);
    var north_reader: std.Io.Reader = .fixed(north_input);
    var south_reader: std.Io.Reader = .fixed(south_input);
    var buffers: [4][256]u8 = undefined;
    var north: Log = .init(&buffers[0], &buffers[1]);
    var south: Log = .init(&buffers[2], &buffers[3]);
    try tryRun(zrx.system(.{
        app.feed.provide(.{
            app.Sensor.north,
            app.Input{ .reader = &north_reader },
            app.Archive{ .writer = &north.archive },
            app.Alerts{ .writer = &north.alerts },
        }),
        app.feed.provide(.{
            app.Sensor.south,
            app.Input{ .reader = &south_reader },
            app.Archive{ .writer = &south.archive },
            app.Alerts{ .writer = &south.alerts },
        }),
    }), .{clock.io()});
    try std.testing.expectEqualStrings(north_alert, north.alerts.buffered());
    try std.testing.expectEqualStrings(north_window, north.archive.buffered());
    try std.testing.expectEqualStrings(south_alert, south.alerts.buffered());
    try std.testing.expectEqualStrings(south_window, south.archive.buffered());
}

test "a malformed or implausible reading fails the run" {
    for ([_][]const u8{ "bad\n", "1,\n", ",3500\n", "1,3500,7\n", "-1,3500\n", "1,150001\n", "1,-100001\n" }) |input| {
        var buffers: [2][256]u8 = undefined;
        var log: Log = .init(&buffers[0], &buffers[1]);
        try std.testing.expectError(error.InvalidReading, replay(.north, input, &log));
    }
}

/// A feed the test holds open: three routine readings, then nothing until
/// the test closes it.
const OpenFeed = struct {
    sent: std.Io.Event = .unset,
    closed: std.Io.Event = .unset,

    fn produce(self: *OpenFeed, out: anytype) !void {
        for ([_][]const u8{ "1,1000", "2,3000", "3,2000" }) |text| {
            if (try out.push(try app.Line.from(text)) == .done) return;
        }
        self.sent.set(io);
        try self.closed.wait(io);
    }
};

/// An archive without a buffer, so that a row is seen when it is written
/// and not at the flush that ends the stream.
const Rows = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    written: std.Io.Event = .unset,
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Rows = @fieldParentPtr("writer", writer);
        const start = self.len;
        for (data[0 .. data.len - 1]) |part| try self.append(part);
        for (0..splat) |_| try self.append(data[data.len - 1]);
        if (std.mem.endsWith(u8, self.text(), "\n")) self.written.set(io);
        return self.len - start;
    }

    fn append(self: *Rows, part: []const u8) std.Io.Writer.Error!void {
        if (part.len > self.bytes.len - self.len) return error.WriteFailed;
        @memcpy(self.bytes[self.len..][0..part.len], part);
        self.len += part.len;
    }

    fn text(self: *const Rows) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn replayOpen(timed: std.Io, feed: *OpenFeed, rows: *Rows, alerts: *std.Io.Writer) !void {
    try tryRun(zrx.program(zrx.fromProducer(app.Line, OpenFeed.produce), app.readings), .{
        timed,
        feed,
        app.Sensor.north,
        app.Archive{ .writer = &rows.writer },
        app.Alerts{ .writer = alerts },
    });
}

test "a window is archived when it is 200 ms old, while its feed is still open" {
    const three = "{\"first_ts_ms\":1,\"last_ts_ms\":3,\"count\":3,\"min_mc\":1000,\"max_mc\":3000,\"sum_mc\":6000}\n";
    var clock: Clock = .init(io);
    var feed: OpenFeed = .{};
    var rows: Rows = .{};
    var no_alerts: std.Io.Writer = .fixed(&.{});
    var run = try io.concurrent(replayOpen, .{ clock.io(), &feed, &rows, &no_alerts });
    defer _ = run.cancel(io) catch {};

    // Written out, not `app.window_age`: the test is what pins the 200 ms.
    try feed.sent.wait(io);
    try clock.waitingAt(.fromMilliseconds(200));
    try std.testing.expectEqualStrings("", rows.text());
    clock.advanceTo(.fromMilliseconds(200));
    try rows.written.wait(io);
    try std.testing.expectEqualStrings(three, rows.text());

    feed.closed.set(io);
    try run.await(io);
    try std.testing.expectEqualStrings(three, rows.text());
}

const Outcome = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Outcome) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Runs the executable in `dir` on `north south north.jsonl south.jsonl`.
fn invoke(dir: std.Io.Dir, args: []const []const u8) !Outcome {
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
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited);
    return .{ .exit = result.term.exited, .stdout = result.stdout, .stderr = result.stderr };
}

const paths = [_][]const u8{ "north", "south", "north.jsonl", "south.jsonl" };

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "the executable publishes an archive per feed and replaces neither" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "north", .data = north_input });
    try temp.dir.writeFile(io, .{ .sub_path = "south", .data = south_input });

    const first = try invoke(temp.dir, &paths);
    defer first.deinit();
    try std.testing.expectEqual(0, first.exit);
    try std.testing.expectEqualStrings("", first.stderr);
    // One whole line per alert; the two feeds' lines come in either order.
    if (!std.mem.eql(u8, first.stdout, north_alert ++ south_alert))
        try std.testing.expectEqualStrings(south_alert ++ north_alert, first.stdout);
    try expectFile(temp.dir, "north.jsonl", north_window);
    try expectFile(temp.dir, "south.jsonl", south_window);

    // Both archives exist now. Alerts are printed as seen, so how many of
    // them precede the failure is not fixed and is not asserted.
    try temp.dir.writeFile(io, .{ .sub_path = "north.jsonl", .data = "kept north\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "south.jsonl", .data = "kept south\n" });
    const second = try invoke(temp.dir, &paths);
    defer second.deinit();
    try std.testing.expectEqual(2, second.exit);
    try std.testing.expectEqualStrings("fatal: PathAlreadyExists\n", second.stderr);
    try expectFile(temp.dir, "north.jsonl", "kept north\n");
    try expectFile(temp.dir, "south.jsonl", "kept south\n");
}

test "the executable publishes no archive for a feed with a malformed reading" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "north", .data = "2,3500\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "south", .data = "bad\n" });
    const outcome = try invoke(temp.dir, &paths);
    defer outcome.deinit();
    try std.testing.expectEqual(2, outcome.exit);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectEqualStrings("fatal: InvalidReading\n", outcome.stderr);
    // The north archive may or may not be there: publication is per file.
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "south.jsonl", .{}));
}

test "the executable rejects any other number of arguments" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const outcome = try invoke(temp.dir, paths[0..3]);
    defer outcome.deinit();
    try std.testing.expectEqual(2, outcome.exit);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectEqualStrings("fatal: InvalidArguments\n", outcome.stderr);
}

/// What a run failed with. `run` returns nothing: a failure goes to a
/// rescue, and a test binds one that hands it back.
const Failure = struct { err: ?anyerror = null };

fn noteFailure(failure: *Failure, err: anyerror) void {
    failure.err = err;
}

/// Runs `runnable` and returns what it failed with.
fn tryRun(runnable: anytype, deps: anytype) anyerror!void {
    var failure: Failure = .{};
    runnable.run(deps ++ .{ &failure, zrx.rescue(noteFailure) });
    if (failure.err) |err| return err;
}
