const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const map = zrx.map;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const batchWithin = zrx.batchWithin;
const forEach = zrx.forEach;

const max_line = 64;
pub const batch_size = 8;
pub const max_age: Io.Duration = .fromMilliseconds(200);
pub const Line = zrx.Line(max_line);
pub const North = struct { reader: *Io.Reader };
pub const South = struct { reader: *Io.Reader };
pub const Sensor = enum { north, south };
const Feed = struct { sensor: Sensor };

const Reading = struct {
    ts_ms: u64,
    temp_mc: i32,

    fn needsAlert(self: Reading) bool {
        return self.temp_mc < 0 or self.temp_mc > 8000;
    }
};

fn parse(line: Line) error{InvalidReading}!Reading {
    const text = std.mem.trimEnd(u8, line.text(), "\r");
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.InvalidReading;
    const ts_ms = std.fmt.parseInt(u64, text[0..comma], 10) catch return error.InvalidReading;
    const temp_mc = std.fmt.parseInt(i32, text[comma + 1 ..], 10) catch return error.InvalidReading;
    if (temp_mc < -100_000 or temp_mc > 150_000) return error.InvalidReading;
    return .{ .ts_ms = ts_ms, .temp_mc = temp_mc };
}

pub const Destination = struct {
    writer: *Io.Writer,
    mutex: Io.Mutex = .init,

    fn emit(self: *Destination, io: Io, record: anytype) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try std.json.Stringify.value(record, .{}, self.writer);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }
};

pub const Alerts = struct { output: *Destination };
pub const Windows = struct { output: *Destination };

fn alert(io: Io, alerts: Alerts, feed: Feed, item: Reading) !void {
    try alerts.output.emit(io, .{
        .kind = "alert",
        .sensor = feed.sensor,
        .ts_ms = item.ts_ms,
        .temp_mc = item.temp_mc,
    });
}

fn saveWindow(io: Io, archive: Windows, feed: Feed, group: zrx.Batch(Reading, batch_size)) !void {
    var minimum: i32 = std.math.maxInt(i32);
    var maximum: i32 = std.math.minInt(i32);
    var sum: i32 = 0;
    for (group.slice()) |item| {
        minimum = @min(minimum, item.temp_mc);
        maximum = @max(maximum, item.temp_mc);
        sum += item.temp_mc;
    }
    try archive.output.emit(io, .{
        .kind = "window",
        .sensor = feed.sensor,
        .first_ts_ms = group.items[0].ts_ms,
        .last_ts_ms = group.items[group.len - 1].ts_ms,
        .count = group.len,
        .min_mc = minimum,
        .max_mc = maximum,
        .sum_mc = sum,
    });
}

const alarms = zrx.pipe(.{forEach(alert)});
const windows = zrx.pipe(.{
    batchWithin(batch_size, max_age),
    forEach(saveWindow),
});
const pipeline = zrx.pipe(.{
    map(parse),
    route(.{
        when(Reading.needsAlert, alarms),
        otherwise(windows),
    }),
});

pub fn feedProgram(source: anytype, sensor: Sensor) @TypeOf(zrx.program(source, pipeline).provide(.{Feed{ .sensor = sensor }})) {
    return zrx.program(source, pipeline).provide(.{Feed{ .sensor = sensor }});
}

pub fn process(io: Io, north: North, south: South, archive: *Io.Writer, alerts: *Io.Writer) !void {
    if (archive == alerts) return error.WritersMustBeDistinct;
    var alert_destination: Destination = .{ .writer = alerts };
    var archive_destination: Destination = .{ .writer = archive };
    const feeds = zrx.system(.{
        feedProgram(zrx.lines(North, max_line), .north),
        feedProgram(zrx.lines(South, max_line), .south),
    });
    try feeds.run(.{
        io,
        north,
        south,
        Alerts{ .output = &alert_destination },
        Windows{ .output = &archive_destination },
    });
}

const usage = "usage: offline-telemetry NORTH SOUTH OUTPUT\n";

pub fn execute(io: Io, args: []const []const u8) !u8 {
    var alerts_buffer: [256]u8 = undefined;
    var alerts = Io.File.stdout().writerStreaming(io, &alerts_buffer);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try alerts.interface.writeAll(usage);
        try alerts.interface.flush();
        return 0;
    }
    if (args.len != 3) return error.InvalidArguments;
    const dir = Io.Dir.cwd();
    const north_file = try dir.openFile(io, args[0], .{});
    defer north_file.close(io);
    const south_file = try dir.openFile(io, args[1], .{});
    defer south_file.close(io);
    var file = try dir.createFileAtomic(io, args[2], .{});
    defer file.deinit(io);
    var north_buffer: [max_line + 1]u8 = undefined;
    var south_buffer: [max_line + 1]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var north = north_file.readerStreaming(io, &north_buffer);
    var south = south_file.readerStreaming(io, &south_buffer);
    var output = file.file.writerStreaming(io, &output_buffer);
    try process(io, .{ .reader = &north.interface }, .{ .reader = &south.interface }, &output.interface, &alerts.interface);
    try file.link(io);
    return 0;
}

test "alert boundaries are inclusive for routine readings" {
    try std.testing.expect(!(Reading{ .ts_ms = 0, .temp_mc = 0 }).needsAlert());
    try std.testing.expect(!(Reading{ .ts_ms = 0, .temp_mc = 8000 }).needsAlert());
    try std.testing.expect((Reading{ .ts_ms = 0, .temp_mc = -1 }).needsAlert());
    try std.testing.expect((Reading{ .ts_ms = 0, .temp_mc = 8001 }).needsAlert());
}
