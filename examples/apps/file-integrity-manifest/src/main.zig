//! A SHA-256 manifest of the files named on the command line, as one program.
//!
//!     paths -> four workers: path -> a regular file -> its bytes -> one digest -> a row
//!                            (or the row of what went wrong)
//!       |- every row -> JSON           -> the manifest file
//!       '- every row -> worst outcome  -> the exit status
const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const zrx = @import("zrx");
const json = zrx.ext.json;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const fileBytes = zrx.fileBytes;
const concurrent = zrx.concurrent;
const each = zrx.each;
const attempt = zrx.attempt;
const branch = zrx.branch;
const map = zrx.map;
const fold = zrx.fold;
const forEach = zrx.forEach;
const write = zrx.write;
const fileWriter = zrx.fileWriter;
const stderr = zrx.stderr;
const rescue = zrx.rescue;

/// Where the rows go.
pub const Manifest = struct { writer: *Io.Writer };

/// One row: a hashed file, or the name of what went wrong with it.
pub const Entry = struct {
    path: []const u8,
    bytes: ?u64 = null,
    sha256: ?[2 * Sha256.digest_length]u8 = null,
    failure: ?[]const u8 = null,
};

/// What the process exits with.
pub const Exit = enum(u8) {
    /// Every file was hashed.
    complete = 0,
    /// The manifest holds a failure row.
    incomplete = 1,
    /// Wrong usage, or the run failed: there is no manifest.
    failed = 2,

    fn after(exit: Exit, row: Entry) Exit {
        return if (row.failure == null) exit else .incomplete;
    }
};

const workers = 4;
/// What one worker reads at a time.
pub const read_bytes = 32 * 1024;

/// The running digest of one file.
const Hash = struct {
    sha: Sha256 = .init(.{}),
    bytes: u64 = 0,

    fn update(hash: Hash, piece: []const u8) Hash {
        var next = hash;
        next.sha.update(piece);
        next.bytes += piece.len;
        return next;
    }
};

/// Only a regular file is opened. A named pipe would wait for a writer, and
/// the whole manifest with it.
fn regularFile(io: Io, path: []const u8) ![]const u8 {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return switch (stat.kind) {
        .file => path,
        .directory => error.IsDir,
        else => error.NotRegularFile,
    };
}

fn bytesOf(path: []const u8) zrx.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}

fn described(file: zrx.Tagged([]const u8, Hash)) Entry {
    var sha = file.item.sha;
    return .{ .path = file.source, .bytes = file.item.bytes, .sha256 = std.fmt.bytesToHex(sha.finalResult(), .lower) };
}

/// A file that cannot be hashed is still a row. It is given a
/// `Failed(anyerror, Path)`, whatever type the paths of this run have.
fn failed(failure: anytype) Entry {
    return .{ .path = failure.item, .failure = @errorName(failure.err) };
}

fn remember(exit: *Exit, outcome: Exit) void {
    exit.* = outcome;
}

const digest = pipe(.{fold(Hash{}, Hash.update)});

/// path -> a regular file -> its bytes -> one digest -> a row
const hashed = pipe(.{
    map(regularFile),
    each(bytesOf, digest),
    map(described),
});

const rows = pipe(.{
    map(json.encode(.{ .emit_null_optional_fields = false })),
    write(Manifest, "{f}\n"),
});

/// Runs once, at the end of the stream, with the outcome of all the rows.
const exit_status = pipe(.{
    fold(Exit.complete, Exit.after),
    forEach(remember),
});

/// Needs `std.Io`, `Manifest` and the `*Exit` the outcome is stored in.
pub const manifest = pipe(.{
    concurrent(workers, .{attempt(hashed, anyerror, .{map(failed)})}),
    branch(.{
        rows,
        exit_status,
    }),
});

/// Whatever ends the run, or keeps it from starting: one best-effort line
/// on stderr, and the status. There is no manifest then.
fn fatal(diagnostics: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.* = .failed;
    diagnostics.writer.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    diagnostics.writer.flush() catch {};
}

/// `file-integrity-manifest OUTPUT FILE...`
pub fn main(init: std.process.Init) u8 {
    var exit: Exit = .complete;
    if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
        if (args.len < 3) {
            refuse(init.io, &exit, error.InvalidArguments);
        } else {
            // A run returns nothing: what fails it goes to `fatal`, once
            // the output has been closed without getting its name.
            program(fromSlice(args[2..]), manifest).run(.{
                init.io,
                &exit,
                rescue(fatal).provide(.{stderr(256)}),
                fileWriter(Manifest, args[1], 8192, .{ .mode = .publish }),
            });
        }
    } else |err| refuse(init.io, &exit, err);
    return @backingInt(exit);
}

/// What fails before there is a run: a program of one item, the failure.
fn refuse(io: Io, exit: *Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(256) });
}
