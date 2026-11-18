const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const map = zrx.map;
const branch = zrx.branch;
const queue = zrx.queue;
const filter = zrx.filter;
const fold = zrx.fold;
const forEach = zrx.forEach;

const max_line = 128;
const queue_depth = 32;
const Line = zrx.Line(max_line);
const Side = enum { left, right };
pub const Left = struct { reader: *Io.Reader };
pub const Right = struct { reader: *Io.Reader };
const Alerts = struct { writer: *Io.Writer };
const TaggedLine = struct { side: Side, line: Line };

fn Tagged(comptime side: Side, comptime Role: type) type {
    return struct {
        pub const zrx_source = {};
        pub const Item = TaggedLine;

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            const Forward = struct {
                next: @TypeOf(down),

                pub fn push(self: @This(), line: Line) !zrx.Flow {
                    return self.next.push(.{ .side = side, .line = line });
                }
            };
            const lines = zrx.lines(Role, max_line);
            try lines.run(env, Forward{ .next = down });
        }
    };
}

const Level = enum { info, warn, @"error" };
const Event = struct {
    side: Side,
    ts_ms: u64,
    level: Level,
    latency_ms: u32,
    service_len: u8,
    service: [32]u8,

    fn isAlert(event: Event) bool {
        return event.level == .@"error";
    }
};

fn parse(item: TaggedLine) error{InvalidLogRecord}!Event {
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, item.line.text(), "\r"), '\t');
    const ts = fields.next() orelse return error.InvalidLogRecord;
    const level = fields.next() orelse return error.InvalidLogRecord;
    const name = fields.next() orelse return error.InvalidLogRecord;
    const elapsed = fields.next() orelse return error.InvalidLogRecord;
    if (fields.next() != null or name.len == 0 or name.len > 32) return error.InvalidLogRecord;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidLogRecord;
    }
    var event: Event = .{
        .side = item.side,
        .ts_ms = std.fmt.parseInt(u64, ts, 10) catch return error.InvalidLogRecord,
        .level = std.meta.stringToEnum(Level, level) orelse return error.InvalidLogRecord,
        .latency_ms = std.fmt.parseInt(u32, elapsed, 10) catch return error.InvalidLogRecord,
        .service_len = @intCast(name.len),
        .service = @splat(0),
    };
    @memcpy(event.service[0..name.len], name);
    return event;
}

const Counts = struct {
    records: u64 = 0,
    warnings: u64 = 0,
    errors: u64 = 0,
    latency_ms: u128 = 0,

    fn add(counts: *Counts, event: Event) void {
        counts.records += 1;
        counts.warnings += @intFromBool(event.level == .warn);
        counts.errors += @intFromBool(event.level == .@"error");
        counts.latency_ms += event.latency_ms;
    }
};

const Summary = struct {
    left: Counts = .{},
    right: Counts = .{},
    total: Counts = .{},

    fn add(previous: Summary, event: Event) Summary {
        var next = previous;
        switch (event.side) {
            .left => next.left.add(event),
            .right => next.right.add(event),
        }
        next.total.add(event);
        return next;
    }
};

fn save(summary: *Summary, value: Summary) void {
    summary.* = value;
}

fn writeAlert(alerts: Alerts, event: Event) !void {
    try std.json.Stringify.value(.{
        .source = event.side,
        .ts_ms = event.ts_ms,
        .service = event.service[0..event.service_len],
        .latency_ms = event.latency_ms,
    }, .{}, alerts.writer);
    try alerts.writer.writeByte('\n');
}

const totals = zrx.pipe(.{
    fold(Summary{}, Summary.add),
    forEach(save),
});

pub fn analyze(io: Io, left: Left, right: Right, alerts: *Io.Writer, report: *Io.Writer) !void {
    var summary: Summary = .{};
    var slots: [queue_depth]Event = undefined;
    const error_events = zrx.pipe(.{
        filter(Event.isAlert),
        queue(&slots),
        forEach(writeAlert),
    });
    const source = zrx.merge(.{ Tagged(.left, Left){}, Tagged(.right, Right){} });
    const logs = zrx.program(source, .{
        map(parse),
        branch(.{
            error_events,
            totals,
        }),
    });
    try logs.run(.{ io, left, right, Alerts{ .writer = alerts }, &summary });
    try alerts.flush();
    try std.json.Stringify.value(summary, .{}, report);
    try report.writeByte('\n');
    try report.flush();
}

const usage = "usage: multi-file-log-analyzer LEFT RIGHT ALERTS\n";

pub fn execute(io: Io, args: []const []const u8) !u8 {
    var report_buffer: [512]u8 = undefined;
    var report = Io.File.stdout().writerStreaming(io, &report_buffer);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try report.interface.writeAll(usage);
        try report.interface.flush();
        return 0;
    }
    if (args.len != 3) return error.InvalidArguments;
    const dir = Io.Dir.cwd();
    const left_file = try dir.openFile(io, args[0], .{});
    defer left_file.close(io);
    const right_file = try dir.openFile(io, args[1], .{});
    defer right_file.close(io);
    var alerts_file = try dir.createFileAtomic(io, args[2], .{});
    defer alerts_file.deinit(io);

    var left_buffer: [max_line + 1]u8 = undefined;
    var right_buffer: [max_line + 1]u8 = undefined;
    var alerts_buffer: [4096]u8 = undefined;
    var left = left_file.readerStreaming(io, &left_buffer);
    var right = right_file.readerStreaming(io, &right_buffer);
    var alerts = alerts_file.file.writerStreaming(io, &alerts_buffer);
    // Publish the archive before exposing success on stdout.
    var summary_storage: [512]u8 = undefined;
    var summary: Io.Writer = .fixed(&summary_storage);
    try analyze(io, .{ .reader = &left.interface }, .{ .reader = &right.interface }, &alerts.interface, &summary);
    try alerts_file.link(io);
    try report.interface.writeAll(summary.buffered());
    try report.interface.flush();
    return 0;
}

test "invalid service and extra columns fail" {
    for ([_][]const u8{ "1\tinfo\tbad service\t2", "1\terror\tapi\t2\tother" }) |text| {
        var line: Line = .{ .bytes = undefined, .len = text.len };
        @memcpy(line.bytes[0..text.len], text);
        try std.testing.expectError(error.InvalidLogRecord, parse(.{ .side = .left, .line = line }));
    }
}
