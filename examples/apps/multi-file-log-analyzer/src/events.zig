//! What a log record is, and what is counted of it.
const std = @import("std");
const zrx = @import("zrx");
const pattern = zrx.ext.pattern;

const pipe = zrx.pipe;
const program = zrx.program;
const fromValue = zrx.fromValue;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const map = zrx.map;
const forEach = zrx.forEach;
const rescue = zrx.rescue;
const compose = zrx.compose;
const field = zrx.field;
const seq = pattern.seq;
const oneOf = pattern.oneOf;
const repeat = pattern.repeat;
const optional = pattern.optional;
const extract = pattern.extract;
const int = pattern.int;
const as = pattern.as;

/// The longest record, not counting its newline.
pub const max_line = 128;
const Line = zrx.Line(max_line);
const Service = zrx.Line(32);

/// Which log a record came from.
pub const Side = enum { left, right };

pub const Level = enum {
    info,
    warn,
    failure,

    /// The words of the log format.
    const words: std.StaticStringMap(Level) = .initComptime(.{
        .{ "info", .info },
        .{ "warn", .warn },
        .{ "error", .failure },
    });

    pub fn from(word: []const u8) error{UnknownLevel}!Level {
        return words.get(word) orelse error.UnknownLevel;
    }
};

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

/// ASCII letters, digits, underscores or dashes, at least one.
const service_name = repeat(oneOf(.{ pattern.alnum, pattern.set("-_") }), .{ .min = 1 });

/// A line of a log: four columns between tabs.
const record = seq(.{
    extract(.ts_ms, int(u64)),
    "\t",
    extract(.level, as(Level, repeat(pattern.lower, .{ .min = 1 }))),
    "\t",
    extract(.service, as(Service, service_name)),
    "\t",
    extract(.latency_ms, int(u32)),
    optional("\r"),
});

/// A record, with the line it was read from and the log that line came from.
const Read = zrx.Found(pattern.Extracted(record), zrx.Tagged(Side, Line));

fn toEvent(read: Read) Event {
    return .{
        .level = read.found.level,
        .entry = .{
            .source = read.item.source,
            .ts_ms = read.found.ts_ms,
            .service = read.found.service,
            .latency_ms = read.found.latency_ms,
        },
    };
}

/// A line that is no record ends the run.
fn refuse(_: zrx.Tagged(Side, Line)) ParseError!Event {
    return error.InvalidLogRecord;
}

/// A line of a log, with the log it came from, as an event.
pub const parsed = pipe(.{route(.{
    when(compose(.{ field(.item), record }), .{map(toEvent)}),
    otherwise(.{map(refuse)}),
})});

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

const Outcome = struct { event: ?Event = null, failure: ?anyerror = null };

fn keep(outcome: *Outcome, parsed_event: Event) void {
    outcome.event = parsed_event;
}

fn failed(outcome: *Outcome, err: anyerror) void {
    outcome.failure = err;
}

/// What `parsed` makes of one line of the log `side`.
fn parse(side: Side, text: []const u8) !Event {
    var outcome: Outcome = .{};
    const line: zrx.Tagged(Side, Line) = .{ .source = side, .item = try .from(text) };
    program(fromValue(line), .{ parsed, forEach(keep) }).run(.{ &outcome, rescue(failed) });
    return outcome.event orelse outcome.failure.?;
}

test "a record becomes an event of its log, and `error` is a failure" {
    const read = try parse(.right, "42\terror\tapi-1\t7\r");
    try std.testing.expectEqual(Level.failure, read.level);
    try std.testing.expectEqual(Side.right, read.entry.source);
    try std.testing.expectEqual(@as(u64, 42), read.entry.ts_ms);
    try std.testing.expectEqualStrings("api-1", read.entry.service.text());
    try std.testing.expectEqual(@as(u32, 7), read.entry.latency_ms);
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
        "1\tinfo\tbad name\t2",
        "1\tinfo\t\t2",
        // Stricter than the parser this replaced, which went through
        // `std.fmt.parseInt` and trimmed every trailing carriage return.
        "+1\tinfo\tapi\t2",
        "-0\tinfo\tapi\t2",
        "1\tinfo\tapi\t-0",
        "1_000\tinfo\tapi\t2",
        "1\tinfo\tapi\t2\r\r",
    }) |text| {
        try std.testing.expectError(error.InvalidLogRecord, parse(.left, text));
    }
}

test "a service name is letters, digits, underscores and dashes" {
    for ([_][]const u8{ "api", "db-2", "a_b", "this-service-name-has-32-letters" }) |name| {
        var line: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer line.deinit();
        try line.writer.print("1\tinfo\t{s}\t2", .{name});
        try std.testing.expectEqualStrings(name, (try parse(.left, line.written())).entry.service.text());
    }
    for ([_][]const u8{ "1\tinfo\tbad service\t2", "1\tinfo\tcaf\xc3\xa9\t2", "1\tinfo\ta.b\t2" }) |text| {
        try std.testing.expectError(error.InvalidLogRecord, parse(.left, text));
    }
}

test "every event is counted for its own log" {
    var summary: Summary = .{};
    for ([_]struct { Side, []const u8 }{
        .{ .left, "1\terror\tapi\t7" },
        .{ .right, "2\twarn\tdb\t3" },
        .{ .left, "3\tinfo\tapi\t5" },
    }) |line| summary = summary.add(try parse(line[0], line[1]));
    try std.testing.expectEqual(Counts{ .records = 2, .errors = 1, .latency_ms = 12 }, summary.left);
    try std.testing.expectEqual(Counts{ .records = 1, .warnings = 1, .latency_ms = 3 }, summary.right);
}
