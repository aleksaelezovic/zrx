//! What a log record is, and what is counted of it.
const std = @import("std");
const zrx = @import("zrx");

/// The longest record, not counting its newline.
pub const max_line = 128;
const Line = zrx.Line(max_line);
const Service = zrx.Line(32);

/// Which log a record came from.
pub const Side = enum { left, right };

pub const Level = enum { info, warn, failure };

/// The words of the log format.
const levels: std.StaticStringMap(Level) = .initComptime(.{
    .{ "info", .info },
    .{ "warn", .warn },
    .{ "error", .failure },
});

/// What a record says besides its level; a failure is archived as this.
pub const Entry = struct {
    source: Side,
    ts_ms: u64,
    service: Service,
    latency_ms: u32,
};

pub const Event = struct {
    level: Level,
    entry: Entry,
};

pub const ParseError = error{InvalidLogRecord};

/// The four tab-separated columns of a record.
fn columns(text: []const u8) ParseError![4][]const u8 {
    var found: [4][]const u8 = undefined;
    var rest = std.mem.splitScalar(u8, text, '\t');
    for (&found) |*column| column.* = rest.next() orelse return error.InvalidLogRecord;
    return if (rest.next() == null) found else error.InvalidLogRecord;
}

/// A line of a log, with the log it came from, as an event.
pub fn parse(line: zrx.Tagged(Side, Line)) ParseError!Event {
    const record = std.mem.trimEnd(u8, line.item.text(), "\r");
    const ts, const level, const service, const latency = try columns(record);
    return .{
        .level = levels.get(level) orelse return error.InvalidLogRecord,
        .entry = .{
            .source = line.source,
            .ts_ms = std.fmt.parseInt(u64, ts, 10) catch return error.InvalidLogRecord,
            .service = Service.from(service) catch return error.InvalidLogRecord,
            .latency_ms = std.fmt.parseInt(u32, latency, 10) catch return error.InvalidLogRecord,
        },
    };
}

/// A service name is ASCII letters, digits, underscores or dashes, at least one.
pub fn isServiceName(service: Service) bool {
    for (service.text()) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return service.len != 0;
}

pub const Counts = struct {
    records: u64 = 0,
    warnings: u64 = 0,
    errors: u64 = 0,
    latency_ms: u64 = 0,

    fn with(counts: Counts, event: Event) Counts {
        return .{
            .records = counts.records + 1,
            .warnings = counts.warnings + @intFromBool(event.level == .warn),
            .errors = counts.errors + @intFromBool(event.level == .failure),
            .latency_ms = counts.latency_ms + event.entry.latency_ms,
        };
    }
};

/// The counters of each log.
pub const Summary = struct {
    left: Counts = .{},
    right: Counts = .{},

    pub fn add(summary: Summary, event: Event) Summary {
        return switch (event.entry.source) {
            .left => .{ .left = summary.left.with(event), .right = summary.right },
            .right => .{ .left = summary.left, .right = summary.right.with(event) },
        };
    }
};

fn tagged(side: Side, text: []const u8) !zrx.Tagged(Side, Line) {
    return .{ .source = side, .item = try .from(text) };
}

test "a record becomes an event of its log, and `error` is a failure" {
    const event = try parse(try tagged(.right, "42\terror\tapi-1\t7\r"));
    try std.testing.expectEqual(Level.failure, event.level);
    try std.testing.expectEqual(Side.right, event.entry.source);
    try std.testing.expectEqual(@as(u64, 42), event.entry.ts_ms);
    try std.testing.expectEqualStrings("api-1", event.entry.service.text());
    try std.testing.expectEqual(@as(u32, 7), event.entry.latency_ms);
}

test "a record that breaks the format is rejected" {
    for ([_][]const u8{
        "",
        "1\tinfo\tapi",
        "1\terror\tapi\t2\tother",
        "x\tinfo\tapi\t2",
        "1\tfailure\tapi\t2",
        "1\tinfo\tthis-service-name-has-33-letters-\t2",
        "1\tinfo\tapi\t-2",
    }) |text| {
        try std.testing.expectError(error.InvalidLogRecord, parse(try tagged(.left, text)));
    }
}

test "a service name is letters, digits, underscores and dashes" {
    for ([_][]const u8{ "api", "db-2", "a_b", "this-service-name-has-32-letters" }) |name| {
        try std.testing.expect(isServiceName(try .from(name)));
    }
    for ([_][]const u8{ "", "bad service", "caf\xc3\xa9", "a.b" }) |name| {
        try std.testing.expect(!isServiceName(try .from(name)));
    }
}

test "every event is counted for its own log" {
    var summary: Summary = .{};
    for ([_]struct { Side, []const u8 }{
        .{ .left, "1\terror\tapi\t7" },
        .{ .right, "2\twarn\tdb\t3" },
        .{ .left, "3\tinfo\tapi\t5" },
    }) |record| summary = summary.add(try parse(try tagged(record[0], record[1])));
    try std.testing.expectEqual(Counts{ .records = 2, .errors = 1, .latency_ms = 12 }, summary.left);
    try std.testing.expectEqual(Counts{ .records = 1, .warnings = 1, .latency_ms = 3 }, summary.right);
}
