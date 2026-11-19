//! What both programs share: how a measurement is written, the statistics
//! of a station, and the report. Nothing here knows of zrx.
const std = @import("std");
const Io = std.Io;

pub const max_name = 100;
pub const max_line = max_name + ";-99.9".len;
pub const max_stations = 10_000;
/// What is read from the file at a time, and what the report is written through.
pub const read_bytes = 64 * 1024;
pub const write_bytes = 16 * 1024;

const Stats = struct {
    min: i16,
    max: i16,
    sum: i128,
    count: u64,

    fn init(value: i16) Stats {
        return .{ .min = value, .max = value, .sum = value, .count = 1 };
    }

    fn add(self: *Stats, value: i16) void {
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.sum += value;
        self.count += 1;
    }

    fn mean(self: Stats) i16 {
        // Nearest integer tenth, with ties rounded toward positive infinity.
        const count: i128 = self.count;
        return @intCast(@divFloor(self.sum + @divFloor(count, 2), count));
    }
};

fn digit(c: u8) error{InvalidMeasurement}!i16 {
    if (c < '0' or c > '9') return error.InvalidMeasurement;
    return c - '0';
}

fn tenths(text: []const u8) error{InvalidMeasurement}!i16 {
    if (text.len == 0) return error.InvalidMeasurement;
    const negative = text[0] == '-';
    const value = text[@intFromBool(negative)..];
    if (value.len < 3 or value.len > 4 or value[value.len - 2] != '.')
        return error.InvalidMeasurement;
    const fraction = try digit(value[value.len - 1]);
    const whole: i16 = if (value.len == 3) try digit(value[0]) else try digit(value[0]) * 10 + try digit(value[1]);
    const result = whole * 10 + fraction;
    return if (negative) -result else result;
}

/// One line taken apart: the station's name, which borrows from the line,
/// and the temperature in tenths of a degree.
pub const Row = struct { station: []const u8, tenths: i16 };

pub fn split(line: []const u8) error{InvalidMeasurement}!Row {
    const sep = std.mem.findScalar(u8, line, ';') orelse return error.InvalidMeasurement;
    if (sep == 0 or sep > max_name) return error.InvalidMeasurement;
    return .{ .station = line[0..sep], .tenths = try tenths(line[sep + 1 ..]) };
}

const Table = std.StringHashMapUnmanaged(Stats);

/// The statistics of every station seen so far. All of its memory is
/// allocated up front: a name is copied the first time it is seen, and
/// nothing is allocated per measurement.
pub const Stations = struct {
    names: [][max_name]u8,
    /// Where the report sorts the names.
    order: [][]const u8,
    stats: Table,

    pub fn init(allocator: std.mem.Allocator) !Stations {
        const names = try allocator.alloc([max_name]u8, max_stations);
        errdefer allocator.free(names);
        const order = try allocator.alloc([]const u8, max_stations);
        errdefer allocator.free(order);
        var stats: Table = .empty;
        try stats.ensureTotalCapacity(allocator, max_stations);
        return .{ .names = names, .order = order, .stats = stats };
    }

    pub fn deinit(self: *Stations, allocator: std.mem.Allocator) void {
        self.stats.deinit(allocator);
        allocator.free(self.order);
        allocator.free(self.names);
    }

    pub fn record(self: *Stations, station: []const u8, value: i16) error{ InvalidMeasurement, TooManyStations }!void {
        if (self.stats.getPtr(station)) |stats| return stats.add(value);
        const index = self.stats.count();
        if (index == max_stations) return error.TooManyStations;
        if (!std.unicode.utf8ValidateSlice(station)) return error.InvalidMeasurement;
        const owned = self.names[index][0..station.len];
        @memcpy(owned, station);
        self.stats.putAssumeCapacityNoClobber(owned, .init(value));
    }

    /// The stations in the challenge's order, to be formatted with `{f}`.
    pub fn report(self: *Stations) Report {
        const names = self.order[0..self.stats.count()];
        var keys = self.stats.keyIterator();
        for (names) |*name| name.* = keys.next().?.*;
        std.mem.sort([]const u8, names, {}, stationLess);
        return .{ .stats = &self.stats, .names = names };
    }
};

/// `{Abha=-23.0/18.0/59.2, Abidjan=...}`: minimum, mean and maximum of each station.
pub const Report = struct {
    stats: *const Table,
    names: []const []const u8,

    pub fn format(report: Report, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeByte('{');
        for (report.names, 0..) |name, i| {
            const stats = report.stats.get(name).?;
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{s}={f}/{f}/{f}", .{ name, Tenths{ .value = stats.min }, Tenths{ .value = stats.mean() }, Tenths{ .value = stats.max } });
        }
        try writer.writeByte('}');
    }
};

/// A temperature as the challenge writes it: one decimal.
const Tenths = struct {
    value: i16,

    pub fn format(tenths_of: Tenths, writer: *Io.Writer) Io.Writer.Error!void {
        const magnitude = @abs(tenths_of.value);
        if (tenths_of.value < 0) try writer.writeByte('-');
        try writer.print("{d}.{d}", .{ magnitude / 10, magnitude % 10 });
    }
};

// Match Java String.compareTo on valid UTF-8 station names. UTF-16 surrogate
// pairs sort before BMP code points at U+E000 and above.
fn orderKey(codepoint: u21) u21 {
    return if (codepoint >= 0x10000)
        codepoint - 0x10000 + 0xd800
    else if (codepoint >= 0xe000)
        codepoint + 0x100000
    else
        codepoint;
}

fn stationLess(_: void, a: []const u8, b: []const u8) bool {
    var first = (std.unicode.Utf8View.initUnchecked(a)).iterator();
    var second = (std.unicode.Utf8View.initUnchecked(b)).iterator();
    while (first.nextCodepoint()) |cp| {
        const other = second.nextCodepoint() orelse return false;
        if (cp != other) return orderKey(cp) < orderKey(other);
    }
    return second.nextCodepoint() != null;
}

test "temperature parsing accepts the challenge range and rejects other shapes" {
    try std.testing.expectEqual(@as(i16, -999), try tenths("-99.9"));
    try std.testing.expectEqual(@as(i16, 420), try tenths("42.0"));
    try std.testing.expectEqual(@as(i16, 7), try tenths("0.7"));
    for ([_][]const u8{ "+1.0", "100.0", "1", "1.00", "1e3", "x.0" }) |text|
        try std.testing.expectError(error.InvalidMeasurement, tenths(text));
}

test "station order uses Java's UTF-16 ordering" {
    try std.testing.expect(stationLess({}, "Zurich", "Åland"));
    try std.testing.expect(stationLess({}, "🌡", "\u{e000}"));
    try std.testing.expect(!stationLess({}, "\u{e000}", "🌡"));
}

test "a full station table still accepts updates to existing stations" {
    const allocator = std.testing.allocator;
    var stations = try Stations.init(allocator);
    defer stations.deinit(allocator);
    var name: [64]u8 = undefined;
    for (0..max_stations) |i| try stations.record(try std.fmt.bufPrint(&name, "station-{d}", .{i}), 0);
    try stations.record("station-0", 10);
    try std.testing.expectEqual(@as(u64, 2), stations.stats.get("station-0").?.count);
    try std.testing.expectError(error.TooManyStations, stations.record("another", 0));
}

test "a line is a name of at most 100 bytes, a semicolon and a temperature" {
    const row = try split("Zurich;-2.5");
    try std.testing.expectEqualStrings("Zurich", row.station);
    try std.testing.expectEqual(@as(i16, -25), row.tenths);
    const longest: [max_name]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, max_name), (try split(longest ++ ";0.0")).station.len);
    for ([_][]const u8{ "", "Zurich", ";1.0", "Zurich;", longest ++ "x;0.0" }) |line|
        try std.testing.expectError(error.InvalidMeasurement, split(line));
}

test "the report has the minimum, the rounded mean and the maximum of each station, in order" {
    const allocator = std.testing.allocator;
    var stations = try Stations.init(allocator);
    defer stations.deinit(allocator);
    for ([_]Row{ .{ .station = "Z", .tenths = 20 }, .{ .station = "A", .tenths = -1 }, .{ .station = "A", .tenths = 0 }, .{ .station = "Z", .tenths = 21 } }) |row|
        try stations.record(row.station, row.tenths);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{A=-0.1/0.0/0.0, Z=2.0/2.1/2.1}", try std.fmt.bufPrint(&buffer, "{f}", .{stations.report()}));
}
