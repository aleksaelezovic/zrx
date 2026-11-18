const std = @import("std");
const Io = std.Io;

const max_name = 100;
pub const max_line = max_name + ";-99.9".len;
const max_stations = 10_000;

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

pub const Stations = struct {
    names: [][max_name]u8,
    stats: std.StringHashMapUnmanaged(Stats),

    pub fn init(allocator: std.mem.Allocator) !Stations {
        const names = try allocator.alloc([max_name]u8, max_stations);
        errdefer allocator.free(names);
        var stats: std.StringHashMapUnmanaged(Stats) = .empty;
        try stats.ensureTotalCapacity(allocator, max_stations);
        return .{ .names = names, .stats = stats };
    }

    pub fn deinit(self: *Stations, allocator: std.mem.Allocator) void {
        self.stats.deinit(allocator);
        allocator.free(self.names);
    }

    pub fn add(self: *Stations, line: []const u8) error{ InvalidMeasurement, TooManyStations }!void {
        const sep = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidMeasurement;
        if (sep == 0 or sep > max_name) return error.InvalidMeasurement;
        const name = line[0..sep];
        const value = try tenths(line[sep + 1 ..]);
        if (self.stats.getPtr(name)) |stats| {
            stats.add(value);
            return;
        }
        const index = self.stats.count();
        if (index == max_stations) return error.TooManyStations;
        if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidMeasurement;
        const owned = self.names[index][0..name.len];
        @memcpy(owned, name);
        self.stats.putAssumeCapacityNoClobber(owned, .init(value));
    }

    pub fn report(self: *const Stations, allocator: std.mem.Allocator, writer: *Io.Writer) !void {
        const names = try allocator.alloc([]const u8, self.stats.count());
        defer allocator.free(names);
        var keys = self.stats.keyIterator();
        for (names) |*name| name.* = keys.next().?.*;
        std.mem.sort([]const u8, names, {}, stationLess);

        try writer.writeByte('{');
        for (names, 0..) |name, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.writeAll(name);
            try writer.writeByte('=');
            const stats = self.stats.get(name).?;
            try printValue(writer, stats.min);
            try writer.writeByte('/');
            try printValue(writer, stats.mean());
            try writer.writeByte('/');
            try printValue(writer, stats.max);
        }
        try writer.writeAll("}\n");
        try writer.flush();
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

fn printValue(writer: *Io.Writer, value: i16) !void {
    const magnitude = @abs(value);
    if (value < 0) try writer.writeByte('-');
    try writer.print("{d}.{d}", .{ magnitude / 10, magnitude % 10 });
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
    var line: [64]u8 = undefined;
    for (0..max_stations) |i| try stations.add(try std.fmt.bufPrint(&line, "station-{d};0.0", .{i}));
    try stations.add("station-0;1.0");
    try std.testing.expectEqual(@as(u64, 2), stations.stats.get("station-0").?.count);
    try std.testing.expectError(error.TooManyStations, stations.add("another;0.0"));
}
