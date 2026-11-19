//! The data journey of a record, as one declaration.
//!
//!     line -> validated outcome -> numbered -> within the record limit
//!       |- accepted records    -> the output file
//!       |- rejected records    -> diagnostics
//!       '- every record        -> totals -> summary
const std = @import("std");
const zrx = @import("zrx");
const records = @import("domain/records.zig");
const validation = @import("domain/validation.zig");
const summaries = @import("domain/summary.zig");

const pipe = zrx.pipe;
const map = zrx.map;
const filter = zrx.filter;
const tap = zrx.tap;
const scan = zrx.scan;
const fold = zrx.fold;
const branch = zrx.branch;
const print = zrx.print;
const compose = zrx.compose;
const orElse = zrx.orElse;

const Numbered = records.Numbered;
const Outcome = records.Outcome;
const Summary = summaries.Summary;

/// Where input lines come from.
const Line = zrx.Line(records.max_line_bytes);
pub const Input = struct { reader: *std.Io.Reader };
/// Where accepted, normalized records go.
pub const Accepted = struct { writer: *std.Io.Writer };
/// Where rejections are reported.
pub const Diagnostics = zrx.Stderr;
/// Where the summary goes.
pub const Console = zrx.Stdout;

/// A line that breaks a rule is still a record: a rejected one.
fn rejected(reason: records.ValidationError, _: Line) Outcome {
    return .reject(reason);
}

fn parse(line: Line) records.ValidationError!records.Record {
    return validation.parseFields(line.text());
}

/// The schema, stage by stage; the first rule a line breaks becomes its outcome.
const validated = orElse(compose(.{
    parse,
    validation.validateIdentifier,
    validation.normalizeName,
    validation.validateAmount,
    Outcome.accept,
}), rejected);

/// The caller decides the exit status from the totals.
fn remember(result: *Summary, summary: Summary) void {
    result.* = summary;
}

const accepted_records = pipe(.{
    filter(Numbered.isAccepted),
    map(Numbered.record),
    print(Accepted, "{f}\n"),
});

const rejections = pipe(.{
    filter(Numbered.isRejected),
    map(Numbered.rejection),
    print(Diagnostics, "{f}\n"),
});

const totals = pipe(.{
    map(Summary.of),
    fold(Summary{}, Summary.add),
    tap(remember),
    print(Console, "{f}\n"),
});

/// Needs `records.Rules`, `Accepted`, `Diagnostics`, `Console` and a `*Summary`.
pub const records_pipe = pipe(.{
    map(validated),
    scan(Numbered{}, Numbered.advance),
    map(Numbered.withinLimit),
    branch(.{
        accepted_records,
        rejections,
        totals,
    }),
});

/// Where the summary and the diagnostics go unless a run says otherwise.
const consoles = .{
    zrx.stdout(256),
    zrx.stderr(1024),
};

/// Processes the lines of `Input`: a file in production, a fixed reader in tests.
pub const processing = zrx.program(zrx.lines(Input, records.max_line_bytes), records_pipe).provide(consoles);

/// Processes the lines of standard input.
pub const from_stdin = zrx.program(zrx.stdinLines(records.max_line_bytes), records_pipe).provide(consoles);

/// Writes one text to standard output.
pub fn announce(text: []const u8) @TypeOf(zrx.program(zrx.fromValue(text), announcement).provide(.{zrx.stdout(1024)})) {
    return zrx.program(zrx.fromValue(text), announcement).provide(.{zrx.stdout(1024)});
}

const announcement = pipe(.{print(Console, "{s}")});
