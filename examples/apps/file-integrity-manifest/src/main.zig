//! A SHA-256 manifest of the files named on the command line, as one program.
//!
//!     paths -> four workers: path -> its bytes -> one digest -> a row
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
const print = zrx.print;
const write = zrx.write;
const fileWriter = zrx.fileWriter;
const stderr = zrx.stderr;

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

fn bytesOf(path: []const u8) zrx.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}

fn described(file: zrx.Tagged([]const u8, Hash)) Entry {
    var sha = file.item.sha;
    return .{ .path = file.source, .bytes = file.item.bytes, .sha256 = std.fmt.bytesToHex(sha.finalResult(), .lower) };
}

/// A file that cannot be hashed is still a row.
fn failed(err: anyerror, path: []const u8) Entry {
    return .{ .path = path, .failure = @errorName(err) };
}

fn remember(exit: *Exit, outcome: Exit) void {
    exit.* = outcome;
}

const digest = pipe(.{fold(Hash{}, Hash.update)});

/// path -> its bytes -> one digest -> a row
const hashed = pipe(.{
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
    concurrent(workers, .{attempt(hashed, failed)}),
    branch(.{
        rows,
        exit_status,
    }),
});

const fatal_report = pipe(.{print(zrx.Stderr, "fatal: {s}\n")});

/// `file-integrity-manifest OUTPUT FILE...`
pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| return fatal(init.io, err);
    if (args.len < 3) return fatal(init.io, error.InvalidArguments);
    var exit: Exit = .complete;
    program(fromSlice(args[2..]), manifest).run(.{
        init.io,
        &exit,
        fileWriter(Manifest, args[1], 8192, .{ .mode = .publish }),
    }) catch |err| return fatal(init.io, err);
    return @backingInt(exit);
}

/// One best-effort line on stderr.
fn fatal(io: Io, err: anyerror) u8 {
    program(fromValue(@errorName(err)), fatal_report).run(.{ io, stderr(256) }) catch {};
    return @backingInt(Exit.failed);
}
