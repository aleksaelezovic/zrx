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
const print = zrx.print;
const compose = zrx.compose;
const field = zrx.field;
const require = zrx.require;
const lines = zrx.lines;
const fromValue = zrx.fromValue;
const fileReader = zrx.fileReader;
const fileWriter = zrx.fileWriter;
const stderr = zrx.stderr;
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

/// Archives the export at `input` as the new file `output`, which gets its
/// name only once every record has been written.
pub fn run(io: std.Io, input: []const u8, output: []const u8) !void {
    try archiving.run(.{
        io,
        fileReader(Input, input, records.max_line + 1),
        fileWriter(Archive, output, 16 * 1024, .{ .mode = .publish }),
    });
}

const failure = pipe(.{print(zrx.Stderr, "fatal: {s}\n")});

/// One best-effort line on stderr for a run that failed.
pub fn report(io: std.Io, err: anyerror) void {
    program(fromValue(@errorName(err)), failure).run(.{ io, stderr(256) }) catch {};
}

test {
    _ = records;
}
