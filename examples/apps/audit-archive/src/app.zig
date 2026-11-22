//! The audit archive, as one pipe.
//!
//!     line -> record -> safe to disclose -> batch -> queue -> record -> JSON -> the archive
const std = @import("std");
const zrx = @import("zrx");
pub const records = @import("records.zig");

const pipe = zrx.pipe;
const program = zrx.program;
const map = zrx.map;
const batch = zrx.batch;
const queue = zrx.queue;
const flatten = zrx.flatten;
const write = zrx.write;
const compose = zrx.compose;
const field = zrx.field;
const require = zrx.require;
const lines = zrx.lines;
const fromValue = zrx.fromValue;
const fileReader = zrx.ext.fs.fileReader;
const fileWriter = zrx.ext.fs.fileWriter;
const process = zrx.ext.process;
const stderr = process.stderr;
const Stderr = process.Stderr;
const rescue = zrx.rescue;
const forEach = zrx.forEach;
const json = zrx.ext.json;

/// Where the export is read from.
pub const Input = struct { reader: *std.Io.Reader };
/// Where archived records go.
pub const Archive = struct { writer: *std.Io.Writer };

pub const batch_size = 32;
pub const queue_depth = 4;

const safe_resource = compose(.{
    field(.resource),
    records.isSafe,
});

/// When the archive is slow the queue fills and the source waits, having
/// handed over `queue_depth + 2` batches: the queued ones, the one being
/// written and the one it waits to put. Needs `std.Io` and `Archive`.
pub const archive = pipe(.{
    map(records.decode),
    map(require(safe_resource, error.UnsafeResource)),
    batch(batch_size),
    queue(queue_depth),
    flatten(),
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});

/// The whole app. `run` gives it files; a test gives it a reader and a writer.
pub const archiving = program(lines(Input, records.max_line), archive);

/// How the app ended, for `main` to return.
pub const Exit = process.Exit;

/// Whatever ends a run: one best-effort line on stderr, exit status 2.
const fatal = process.fail(.{ .status = 2, .prefix = "fatal" });

/// Archives the export at `input` as the new file `output`, which gets its
/// name only once every record has been written. A run returns nothing:
/// what fails it goes to `fatal`, once both files are closed.
pub fn run(io: std.Io, input: []const u8, output: []const u8, exit: *Exit) void {
    archiving.run(.{
        io,
        exit,
        rescue(fatal).provide(.{stderr(Stderr, 256)}),
        fileReader(Input, input, records.max_line + 1),
        fileWriter(Archive, output, 16 * 1024, .{ .mode = .publish }),
    });
}

/// The same line and status for what fails before there is a run, such as
/// a wrong argument count: a program of one item, the failure.
pub fn refuse(io: std.Io, exit: *Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(Stderr, 256) });
}

test {
    _ = records;
}
