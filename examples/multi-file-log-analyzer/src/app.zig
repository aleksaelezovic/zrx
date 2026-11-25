//! Two service logs, read together.
//!
//!     left log  -.
//!                 >- line -> event
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
const fileReader = zrx.ext.fs.fileReader;
const fileWriter = zrx.ext.fs.fileWriter;
const process = zrx.ext.process;
const stdout = process.stdout;
const stderr = process.stderr;
const rescue = zrx.rescue;
const forEach = zrx.forEach;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const queue = zrx.queue;
const branch = zrx.branch;
const print = zrx.print;
const write = zrx.write;
const compose = zrx.compose;
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
pub const Report = process.Stdout;
/// Where a failed run says why.
pub const Diagnostics = process.Stderr;

const isFailure = compose(.{
    field(.level),
    eq(.failure),
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
    events.parsed,
    branch(.{
        alerts,
        totals,
    }),
});

/// How the app ended, for `main` to return.
pub const Exit = process.Exit;

/// Whatever ends a run: one best-effort line on stderr, exit status 2.
const fatal = process.fail(.{ .status = 2, .prefix = "fatal" });

/// The same line and status for what fails before there is a run, such as
/// a wrong argument count: a program of one item, the failure.
pub fn refuse(io: std.Io, exit: *Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(Diagnostics, 256) });
}

/// Runs what `args` (without argv[0]) asks for: `LEFT RIGHT ALERTS`. The
/// alerts file gets its name once the run has succeeded. A run returns
/// nothing: what fails it goes to `fatal`, once the files are closed.
pub fn execute(io: std.Io, args: []const []const u8, exit: *Exit) void {
    if (args.len != 3) return refuse(io, exit, error.InvalidArguments);
    analyzer.run(.{
        io,
        exit,
        rescue(fatal).provide(.{stderr(Diagnostics, 256)}),
        fileReader(Left, args[0], max_line + 1),
        fileReader(Right, args[1], max_line + 1),
        fileWriter(Alerts, args[2], 4096, .{ .mode = .publish }),
        stdout(Report, 512),
    });
}

test {
    _ = events;
}
