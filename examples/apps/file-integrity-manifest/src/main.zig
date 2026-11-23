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
const fs = zrx.ext.fs;
const process = zrx.ext.process;

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const fileBytes = fs.fileBytes;
const concurrent = zrx.concurrent;
const each = zrx.each;
const attempt = zrx.attempt;
const branch = zrx.branch;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const forEach = zrx.forEach;
const write = zrx.write;
const compose = zrx.compose;
const field = zrx.field;
const ne = zrx.ne;
const fileWriter = fs.fileWriter;
const stderr = process.stderr;
const Stderr = process.Stderr;
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

/// What the process exits with: 0 when every file was hashed.
pub const status = struct {
    /// The manifest holds a failure row.
    pub const incomplete = 1;
    /// Wrong usage, or the run failed: there is no manifest.
    pub const failed = 2;
};

const workers = 4;
/// What one worker reads at a time.
pub const read_bytes = 32 * 1024;

const Digest = zrx.ext.bytes.digest(Sha256.init(.{}));

/// The running digest of one file, and how much of it was read.
const Hash = struct {
    sha: Digest = .{},
    bytes: u64 = 0,

    fn update(hash: Hash, piece: []const u8) Hash {
        return .{ .sha = hash.sha.update(piece), .bytes = hash.bytes + piece.len };
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

fn bytesOf(path: []const u8) fs.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}

fn described(file: zrx.Tagged([]const u8, Hash)) Entry {
    return .{ .path = file.source, .bytes = file.item.bytes, .sha256 = std.fmt.bytesToHex(file.item.sha.final(), .lower) };
}

/// A file that cannot be hashed is still a row. It is given a
/// `Failed(anyerror, Path)`, whatever type the paths of this run have.
fn failed(failure: anytype) Entry {
    return .{ .path = failure.item, .failure = @errorName(failure.err) };
}

const hasFailed = compose(.{ field(.failure), ne(null) });

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

/// A row of what went wrong leaves its status: the manifest is there, and
/// it is not whole. After the workers, so that one task writes the status.
const exit_status = pipe(.{
    filter(hasFailed),
    forEach(process.status(status.incomplete)),
});

/// Needs `std.Io`, `Manifest` and the `*process.Exit` the outcome is stored in.
pub const manifest = pipe(.{
    concurrent(workers, .{attempt(hashed, anyerror, .{map(failed)})}),
    branch(.{
        rows,
        exit_status,
    }),
});

/// Whatever ends the run, or keeps it from starting: one best-effort line
/// on stderr, and the status. There is no manifest then.
const fatal = process.fail(.{ .status = status.failed, .prefix = "fatal" });

/// `file-integrity-manifest OUTPUT FILE...`
pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    if (init.minimal.args.toSlice(init.arena.allocator())) |args| {
        if (args.len < 3) {
            refuse(init.io, &exit, error.InvalidArguments);
        } else {
            // A run returns nothing: what fails it goes to `fatal`, once
            // the output has been closed without getting its name.
            program(fromSlice(args[2..]), manifest).run(.{
                init.io,
                &exit,
                rescue(fatal).provide(.{stderr(Stderr, 256)}),
                fileWriter(Manifest, args[1], 8192, .{ .mode = .publish }),
            });
        }
    } else |err| refuse(init.io, &exit, err);
    return exit.code;
}

/// What fails before there is a run: a program of one item, the failure.
fn refuse(io: Io, exit: *process.Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(Stderr, 256) });
}
