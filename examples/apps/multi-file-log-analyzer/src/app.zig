//! Two service logs, read together.
//!
//!     left log  -.
//!                 >- line -> event -> with a service name
//!     right log -'     |- failures    -> queue -> JSON lines -> the alerts file
//!                      '- every event -> counters per log -> JSON -> stdout
const std = @import("std");
const zrx = @import("zrx");
pub const events = @import("events.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const mergeTagged = zrx.mergeTagged;
const fromValue = zrx.fromValue;
const lines = zrx.lines;
const fileReader = zrx.fileReader;
const fileWriter = zrx.fileWriter;
const stdout = zrx.stdout;
const stderr = zrx.stderr;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const queue = zrx.queue;
const branch = zrx.branch;
const print = zrx.print;
const write = zrx.write;
const compose = zrx.compose;
const require = zrx.require;
const field = zrx.field;
const eq = zrx.eq;
const json = zrx.ext.json;

const Summary = events.Summary;
const max_line = events.max_line;

/// Where the two logs come from.
pub const Left = struct { reader: *std.Io.Reader };
pub const Right = struct { reader: *std.Io.Reader };
/// Where the failures go.
pub const Alerts = struct { writer: *std.Io.Writer };
/// Where the summary goes.
pub const Report = zrx.Stdout;
/// Where a failed run says why.
pub const Diagnostics = zrx.Stderr;

const isFailure = compose(.{
    field(.level),
    eq(.failure),
});

const hasServiceName = compose(.{
    field(.entry),
    field(.service),
    events.isServiceName,
});

const alerts = pipe(.{
    filter(isFailure),
    map(field(.entry)),
    queue(32),
    map(json.encode(.{})),
    write(Alerts, "{f}\n"),
});

const totals = pipe(.{
    fold(Summary{}, Summary.add),
    map(json.encode(.{})),
    print(Report, "{f}\n"),
});

const logs = mergeTagged(events.Side, .{
    .left = lines(Left, max_line),
    .right = lines(Right, max_line),
});

/// Needs `std.Io`, `Left`, `Right`, `Alerts` and `Report`.
pub const analyzer = program(logs, .{
    map(events.parse),
    map(require(hasServiceName, error.InvalidLogRecord)),
    branch(.{
        alerts,
        totals,
    }),
});

/// Runs what `args` (without argv[0]) asks for: `LEFT RIGHT ALERTS`. The
/// alerts file gets its name once the run has succeeded.
pub fn execute(io: std.Io, args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    try analyzer.run(.{
        io,
        fileReader(Left, args[0], max_line + 1),
        fileReader(Right, args[1], max_line + 1),
        fileWriter(Alerts, args[2], 4096, .{ .mode = .publish }),
        stdout(512),
    });
}

const failure = pipe(.{print(Diagnostics, "fatal: {s}\n")});

/// Says on stderr why a run failed, as well as it can.
pub fn report(io: std.Io, err: anyerror) void {
    program(fromValue(@errorName(err)), failure).run(.{ io, stderr(256) }) catch {};
}

test {
    _ = events;
}
