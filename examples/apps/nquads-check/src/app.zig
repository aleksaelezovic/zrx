//! Checks a file of N-Quads and writes its statements the one way.
//!
//!     line -> numbered -.- nothing or a comment
//!                       |- a statement      -> counted -> tidied -> the output file
//!                       |- nested too deep  -> counted -> "line N: nested deeper than 4" on stderr
//!                       '- anything else    -> counted -> "line N: not a statement" on stderr
const std = @import("std");
const zrx = @import("zrx");
pub const nquads = @import("nquads.zig");
const json = zrx.ext.json;

const pipe = zrx.pipe;
const program = zrx.program;
const fromValue = zrx.fromValue;
const lines = zrx.lines;
const fileReader = zrx.fileReader;
const fileWriter = zrx.fileWriter;
const stdout = zrx.stdout;
const stderr = zrx.stderr;
const rescue = zrx.rescue;
const scan = zrx.scan;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const map = zrx.map;
const tap = zrx.tap;
const drain = zrx.drain;
const forEach = zrx.forEach;
const print = zrx.print;
const write = zrx.write;
const compose = zrx.compose;
const field = zrx.field;

const max_line = nquads.max_line;
const Line = zrx.Line(max_line);

/// Where the lines come from.
pub const Input = struct { reader: *std.Io.Reader };
/// Where the statements go.
pub const Output = struct { writer: *std.Io.Writer };
/// Where a line that is no statement is reported.
pub const Diagnostics = zrx.Stderr;
/// Where the summary goes.
pub const Console = zrx.Stdout;

/// A line with its place in the file, counted from 1.
const Numbered = struct {
    number: usize = 0,
    line: Line = .{ .bytes = undefined, .len = 0 },

    fn next(previous: Numbered, line: Line) Numbered {
        return .{ .number = previous.number + 1, .line = line };
    }
};

/// What a file held.
pub const Summary = struct {
    statements: usize = 0,
    in_graphs: usize = 0,
    rejected: usize = 0,

    fn statement(summary: *Summary, quad: nquads.Quad) void {
        summary.statements += 1;
        summary.in_graphs += @intFromBool(quad.graph != null);
    }

    fn rejection(summary: *Summary, _: usize) void {
        summary.rejected += 1;
    }
};

const isEmpty = compose(.{
    field(.line),
    nquads.empty,
});

const isStatement = compose(.{
    field(.line),
    nquads.statement,
});

const tidied = pipe(.{
    map(field(.found)),
    tap(Summary.statement),
    map(nquads.Tidy.of),
    write(Output, "{f}\n"),
});

const too_long = pipe(.{
    map(field(.item)),
    map(field(.number)),
    tap(Summary.rejection),
    print(Diagnostics, std.fmt.comptimePrint("line {{d}}: longer than {d} bytes once tidied\n", .{max_line})),
});

/// Written the one way, a statement fits a line: what is written can be read again.
const fitsALine = compose(.{
    field(.found),
    nquads.Tidy.of,
    nquads.Tidy.fits,
});

const statements = pipe(.{route(.{
    when(fitsALine, tidied),
    otherwise(too_long),
})});

const isTooDeep = compose(.{
    field(.line),
    nquads.deeper_statement,
});

const too_deep = pipe(.{
    map(field(.item)),
    map(field(.number)),
    tap(Summary.rejection),
    print(Diagnostics, std.fmt.comptimePrint("line {{d}}: nested deeper than {d}\n", .{nquads.max_nesting})),
});

const rejections = pipe(.{
    map(field(.number)),
    tap(Summary.rejection),
    print(Diagnostics, "line {d}: not a statement\n"),
});

/// Needs `Input`, `Output`, `Diagnostics` and a `*Summary`.
pub const check = program(lines(Input, max_line), .{
    scan(Numbered{}, Numbered.next),
    route(.{
        when(isEmpty, .{drain()}),
        when(isStatement, statements),
        when(isTooDeep, too_deep),
        otherwise(rejections),
    }),
});

/// How the app ended, for `main` to return.
pub const Exit = struct { code: u8 = 0 };

/// A file with a line that is no statement: exit status 1.
fn judge(exit: *Exit, summary: Summary) void {
    if (summary.rejected != 0) exit.code = 1;
}

/// What is said of a file once it has been read. Needs `Console` and an `*Exit`.
pub const report = pipe(.{
    tap(judge),
    map(json.encode(.{})),
    print(Console, "{f}\n"),
});

/// Whatever ends a run: one best-effort line on stderr, exit status 2.
fn fatal(diagnostics: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.code = 2;
    diagnostics.writer.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    diagnostics.writer.flush() catch {};
}

/// The same line and status for what fails before there is a run, such as
/// a wrong argument count: a program of one item, the failure.
pub fn refuse(io: std.Io, exit: *Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(256) });
}

/// Runs what `args` (without argv[0]) asks for: `INPUT OUTPUT`. The output
/// gets its name once the file has been read. A run returns nothing: what
/// fails it goes to `fatal`.
pub fn execute(io: std.Io, args: []const []const u8, exit: *Exit) void {
    if (args.len != 2) return refuse(io, exit, error.InvalidArguments);
    var summary: Summary = .{};
    check.run(.{
        io,
        exit,
        &summary,
        rescue(fatal).provide(.{stderr(256)}),
        fileReader(Input, args[0], max_line + 1),
        fileWriter(Output, args[1], 4096, .{ .mode = .publish }),
        stderr(256),
    });
    if (exit.code != 0) return;
    program(fromValue(summary), report).run(.{ io, exit, rescue(fatal).provide(.{stderr(256)}), stdout(256) });
}

test {
    _ = nquads;
}
