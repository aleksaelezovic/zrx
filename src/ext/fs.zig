//! Files and directories, on top of `std.Io.Dir` and `std.Io.File`.
//!
//!     const sources = program(fs.walk("src", 512, 16), .{
//!         filter(isZigFile),
//!         map(field(.path)),
//!         print(Stdout, "{f}\n"),
//!     });
//!
//! A file is a binding or a source. `fileReader` and `fileWriter` bind a
//! file as a role for the duration of a program, for `lines(Role, n)` to
//! read and `print` or `write` to write, where a test binds a reader or a
//! writer of its own. `fileLines` and `fileBytes` are sources that open the
//! file at a path when they run. They borrow the path: its bytes must stay
//! alive through the run. A `source_of` may pass on a slice its item holds,
//! whose bytes live elsewhere, but not a slice of text the item holds
//! inline, such as an entry's path: that handler is given a copy of the
//! item, which is gone before the source runs.
//!
//! `entries` gives the entries of one directory and `walk` those under it,
//! as deep as it was given room for. A directory is named by its path, as a
//! file is for `fileLines`: it is opened when the source runs and closed
//! when the source ends, whichever way it ends. An item holds its path, so
//! it may cross a `queue`; the path begins with the directory's as it was
//! given, so it opens with whatever opens a path. A source holds its
//! directory's path too, so one may be made from an entry: `each(listing,
//! ...)` lists the directories a walk found, each as an item of its own.
//!
//! Nothing here allocates: a buffer, the longest path and the depth of a
//! walk are written where the binding or the source is made, and what does
//! not fit fails the run with an error of its own name.
//!
//! Nothing here is known to the core: these are bindings and sources like
//! any other.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const di = @import("../di.zig");
const text_io = @import("../io.zig");
const Line = text_io.Line;
const Stop = @import("../completion.zig").Stop;

// ---------------------------------------------------------------------------
// Files as bindings
// ---------------------------------------------------------------------------

pub const FileMode = enum {
    /// Create the file, or empty it if it exists.
    replace,
    /// Create the file; `error.PathAlreadyExists` if something is there.
    create_new,
    /// Write to a temporary file in the same directory, and give it its name
    /// once everything this binding wraps has returned without an error and
    /// the writer is flushed. A failure before publication leaves the
    /// destination untouched. If the path already exists at publication,
    /// the run fails with `error.PathAlreadyExists`. With several published
    /// files, the last one acquired is named first. Any files already published
    /// stay in place if a later publication fails.
    publish,
};

pub const FileWriterOptions = struct {
    mode: FileMode = .replace,
};

/// Creates a file and binds its writer as `Role` for the duration of a
/// program.
pub fn fileWriter(
    comptime Role: type,
    path: []const u8,
    comptime buffer_size: usize,
    options: FileWriterOptions,
) FileWriter(Role, buffer_size) {
    return .{ .path = path, .options = options };
}

fn FileWriter(comptime Role: type, comptime buffer_size: usize) type {
    expectRole("fileWriter", Role, "writer", Io.Writer);
    return struct {
        path: []const u8,
        options: FileWriterOptions,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const io = di.get(env, Io);
            var buffer: [buffer_size]u8 = undefined;
            if (self.options.mode == .publish) {
                var pending = try Dir.cwd().createFileAtomic(io, self.path, .{});
                defer pending.deinit(io);
                var writer = pending.file.writer(io, &buffer);
                try next.call(roleOf(&writer.interface));
                try writer.interface.flush();
                return pending.link(io);
            }
            const file = try Dir.cwd().createFile(io, self.path, .{ .exclusive = self.options.mode == .create_new });
            defer file.close(io);
            var writer = file.writer(io, &buffer);
            return next.call(roleOf(&writer.interface));
        }

        fn roleOf(writer: *Io.Writer) Role {
            return if (Role == *Io.Writer) writer else .{ .writer = writer };
        }
    };
}

/// Opens the file at `path` and binds its reader as `Role` for the duration
/// of a program, for `lines(Role, n)` to read. With `lines`, `buffer_size`
/// must be at least the line limit plus one, for the newline.
///
/// A program over `lines(Role, n)` is the same value whether its reader is a
/// file (this binding), standard input (`process.stdin`) or one a test
/// supplies in its place. A failed read fails the run with
/// `error.ReadFailed`, as with any reader given to `lines`.
pub fn fileReader(comptime Role: type, path: []const u8, comptime buffer_size: usize) FileReader(Role, buffer_size) {
    return .{ .path = path };
}

fn FileReader(comptime Role: type, comptime buffer_size: usize) type {
    expectRole("fileReader", Role, "reader", Io.Reader);
    return struct {
        path: []const u8,

        pub const zrx_resource = {};
        pub const Provides = Role;
        pub const needs: []const type = &.{Io};

        pub fn bind(self: @This(), env: anytype, next: anytype) !void {
            const io = di.get(env, Io);
            const file = try Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            var buffer: [buffer_size]u8 = undefined;
            var reader = file.reader(io, &buffer);
            return next.call(if (Role == *Io.Reader) &reader.interface else Role{ .reader = &reader.interface });
        }
    };
}

/// A role is the type a file is keyed by: the interface itself, or a struct
/// of the caller's with that one field.
fn expectRole(comptime who: []const u8, comptime Role: type, comptime field: []const u8, comptime Interface: type) void {
    const interface = "*std." ++ @typeName(Interface);
    const one_field = "`" ++ field ++ ": " ++ interface ++ "` field";
    if (Role == *Interface) return;
    if (@typeInfo(Role) != .@"struct" or !@hasField(Role, field) or @FieldType(Role, field) != *Interface) @compileError(
        who ++ ": `" ++ @typeName(Role) ++ "` is not a " ++ field ++ " role; use `" ++ interface ++ "` or a struct with a " ++ one_field,
    );
    if (@typeInfo(Role).@"struct".field_names.len != 1) @compileError(
        who ++ ": use `" ++ interface ++ "` or a role with a single " ++ one_field,
    );
}

// ---------------------------------------------------------------------------
// Files as sources
// ---------------------------------------------------------------------------

/// The lines of the file at `path`, opened when the program runs and closed
/// when it ends. A line may be at most `max_line_bytes` long, not counting
/// its `\n`; a longer one fails the run with `error.StreamTooLong`. A failed
/// read fails the run with the error the system reported. `path` is
/// borrowed: its bytes must stay alive through the run, so it is not text
/// held inline in the item of a `source_of`. Needs `std.Io`.
pub fn fileLines(path: []const u8, comptime max_line_bytes: usize) FileLines(max_line_bytes) {
    return .{ .path = path };
}

fn FileLines(comptime max_line_bytes: usize) type {
    return struct {
        path: []const u8,

        pub const zrx_source = {};
        pub const Item = Line(max_line_bytes);

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectFileIo("fileLines", @TypeOf(env));
            const io = di.get(env, Io);
            const file = try Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            // Room for the longest line and the newline that ends it.
            var buffer: [max_line_bytes + 1]u8 = undefined;
            var reader = file.reader(io, &buffer);
            // The lines of a reader are the core's: this source is `lines`
            // over the reader it opened.
            const of_reader = text_io.lines(*Io.Reader, max_line_bytes);
            return of_reader.run(.{&reader.interface}, down) catch |err| readCause(&reader, err);
        }
    };
}

/// `std.Io.File.Reader` reports a failed read as `error.ReadFailed` and keeps
/// what the system said. This gives a read that just failed on `reader` that
/// cause. Use it where the read happens: further from it, a `ReadFailed` may
/// be another reader's, which is why `fileReader` does not translate.
fn readCause(reader: *const Io.File.Reader, err: anytype) (@TypeOf(err) || Io.File.Reader.Error) {
    if (@as(anyerror, err) == error.ReadFailed) if (reader.err) |cause| return cause;
    return err;
}

/// The bytes of the file at `path`, at most `max_bytes` at a time, opened
/// when the source runs and closed when it ends. An item is a slice into
/// the source's own buffer: it is valid until the push that carries it
/// returns, so a stage that keeps bytes copies them. A failed read fails
/// the run with the error the system reported. `path` is borrowed: its
/// bytes must stay alive through the run, so it is not text held inline in
/// the item of a `source_of`. Needs `std.Io`.
pub fn fileBytes(path: []const u8, comptime max_bytes: usize) FileBytes(max_bytes) {
    return .{ .path = path };
}

/// The type of `fileBytes(path, max_bytes)`, for a handler that returns one.
pub fn FileBytes(comptime max_bytes: usize) type {
    if (max_bytes == 0) @compileError("fileBytes: needs room for at least one byte at a time; pass a positive comptime size such as `fileBytes(path, 4096)`");
    return struct {
        path: []const u8,

        pub const zrx_source = {};
        pub const Item = []const u8;

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectFileIo("fileBytes", @TypeOf(env));
            const io = di.get(env, Io);
            const file = try Dir.cwd().openFile(io, self.path, .{});
            defer file.close(io);
            var buffer: [max_bytes]u8 = undefined;
            var reader = file.reader(io, &buffer);
            while (true) {
                const bytes = reader.interface.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return,
                    // The reader keeps what went wrong to itself.
                    error.ReadFailed => return reader.err orelse err,
                };
                if (try down.push(bytes) == .done) return;
                reader.interface.toss(bytes.len);
            }
        }
    };
}

fn expectFileIo(comptime who: []const u8, comptime Env: type) void {
    if (!di.has(Env, Io)) @compileError(
        who ++ ": needs dependency `" ++ @typeName(Io) ++ "`, which is not provided here; provided: " ++ di.listTypes(di.types(Env)),
    );
}

// ---------------------------------------------------------------------------
// Directories as sources
// ---------------------------------------------------------------------------

/// What a directory holds under one name: the path to it, of at most
/// `max_path_bytes`, and what kind of thing it is. A symbolic link is of
/// kind `.sym_link`, whatever it points to.
pub fn Entry(comptime max_path_bytes: usize) type {
    return struct {
        /// The path of the directory as it was given, a separator and the
        /// names below it: what opens this entry from where the source was run.
        path: Line(max_path_bytes),
        kind: Io.File.Kind,

        /// The last name of the path. It borrows from the entry it is asked of.
        pub fn name(entry: *const @This()) []const u8 {
            return Dir.path.basename(entry.path.text());
        }
    };
}

/// The entries of the directory at `path`, without `.` and `..`, in the order
/// the system lists them. Subdirectories are entries and are not gone into;
/// `walk` does that. A path longer than `max_path_bytes` fails the run with
/// `error.PathTooLong`, the directory's own included, and an entry's path
/// that `std` would not open with `error.NameTooLong`: one of
/// `std.fs.max_path_bytes` bytes or more, or on Windows of more than
/// `PATH_MAX_WIDE` units of UTF-16. `path` is copied: it need not outlive
/// this call. Needs `std.Io`.
pub fn entries(path: []const u8, comptime max_path_bytes: usize) Entries(max_path_bytes) {
    return .{ .path = Line(max_path_bytes).from(path) catch null };
}

/// The type of `entries(path, max_path_bytes)`, for a handler that returns one.
pub fn Entries(comptime max_path_bytes: usize) type {
    expectRoom("fs.entries", "fs.entries(path, 1024)", max_path_bytes);
    return struct {
        /// The directory, or null when its own path is too long.
        path: ?Line(max_path_bytes),

        pub const zrx_source = {};
        pub const zrx_stop_source = true;
        pub const Item = Entry(max_path_bytes);

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectIo("fs.entries", @TypeOf(env));
            const io = di.get(env, Io);
            const stop = stopOf(env);
            var path = self.path orelse return error.PathTooLong;
            if (!opens(native, path.text())) return error.NameTooLong;
            const root_len = path.len;
            const dir = try Dir.cwd().openDir(io, path.text(), .{ .iterate = true });
            defer dir.close(io);
            var listing = dir.iterateAssumeFirstIteration();
            while (!stop.requested()) {
                const found = try listing.next(io) orelse return;
                try join(max_path_bytes, &path, root_len, found.name);
                if (try down.push(Item{ .path = path, .kind = try kindOf(io, dir, found) }) == .done) return;
            }
        }
    };
}

/// The entries under the directory at `path`, without `.` and `..`. A
/// directory is an entry, and comes before what is in it; beyond that the
/// order is the system's. A symbolic link is an entry and is not followed.
///
/// The walk is inside of at most `max_depth` directories at once, the one it
/// was given being the first: with a depth of 1 it lists that one, and a
/// directory in it is one too many. A directory deeper than that fails the
/// run with `error.TooDeep`, after it was given as an entry. A path longer
/// than `max_path_bytes` fails it with `error.PathTooLong`, one that `std`
/// would not open (as for `entries`) with `error.NameTooLong`, and a
/// directory that cannot be opened or read fails it with what the system
/// reported: nothing is left out silently.
///
/// `path` is copied: it need not outlive this call. Needs `std.Io` and no
/// allocator: the listings of the directories it is inside of are on the
/// stack of the task that runs the source, `@sizeOf(std.Io.Dir.Iterator)`
/// and a length for each of the `max_depth`.
pub fn walk(path: []const u8, comptime max_path_bytes: usize, comptime max_depth: usize) Walk(max_path_bytes, max_depth) {
    return .{ .path = Line(max_path_bytes).from(path) catch null };
}

/// The type of `walk(path, max_path_bytes, max_depth)`, for a handler that returns one.
pub fn Walk(comptime max_path_bytes: usize, comptime max_depth: usize) type {
    expectRoom("fs.walk", "fs.walk(path, 1024, 16)", max_path_bytes);
    if (max_depth == 0) @compileError(
        "fs.walk: a depth of 0 has no room for the directory the walk is given; pass a positive comptime depth such as `fs.walk(path, 1024, 16)`",
    );
    return struct {
        /// The directory, or null when its own path is too long.
        path: ?Line(max_path_bytes),

        pub const zrx_source = {};
        pub const zrx_stop_source = true;
        pub const Item = Entry(max_path_bytes);

        /// A directory the walk is inside of. `std`'s walker keeps the same
        /// in a list that grows, and its `deinit` leaves the directories
        /// open when the walk ends before the listing does, which here is
        /// every early stop.
        const Level = struct {
            listing: Dir.Iterator,
            /// How much of the path is this directory's.
            path_len: usize,
        };

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectIo("fs.walk", @TypeOf(env));
            const io = di.get(env, Io);
            const stop = stopOf(env);
            var path = self.path orelse return error.PathTooLong;
            if (!opens(native, path.text())) return error.NameTooLong;

            // The directories the walk is inside of, the one it was given first.
            var levels: [max_depth]Level = undefined;
            var depth: usize = 0;
            defer for (levels[0..depth]) |*level| level.listing.reader.dir.close(io);

            const root = try Dir.cwd().openDir(io, path.text(), .{ .iterate = true });
            levels[0] = .{ .listing = root.iterateAssumeFirstIteration(), .path_len = path.len };
            depth = 1;

            while (depth != 0 and !stop.requested()) {
                const top = &levels[depth - 1];
                const dir = top.listing.reader.dir;
                const found = try top.listing.next(io) orelse {
                    dir.close(io);
                    depth -= 1;
                    continue;
                };
                try join(max_path_bytes, &path, top.path_len, found.name);
                const kind = try kindOf(io, dir, found);
                // The directory is an item before it is opened: a pipe that
                // is done with it does not have it opened.
                if (try down.push(Item{ .path = path, .kind = kind }) == .done) return;
                if (kind != .directory) continue;
                if (depth == max_depth) return error.TooDeep;
                // Not through a link, if the name has become one since it was
                // listed. Tested on Linux and macOS only: on Windows `std`
                // opens a reparse point itself, and nothing here checks that.
                const below = try dir.openDir(io, found.name, .{ .iterate = true, .follow_symlinks = false });
                levels[depth] = .{ .listing = below.iterateAssumeFirstIteration(), .path_len = path.len };
                depth += 1;
            }
        }
    };
}

fn expectRoom(comptime who: []const u8, comptime example: []const u8, comptime max_path_bytes: usize) void {
    if (max_path_bytes == 0) @compileError(
        who ++ ": a path needs room for at least one byte; pass a positive comptime size such as `" ++ example ++ "`",
    );
}

fn expectIo(comptime who: []const u8, comptime Env: type) void {
    if (!di.has(Env, Io)) @compileError(who ++ ": needs `std.Io` to read a directory; pass `io` to `run(.{ io, ... })`");
}

/// A source run by something that does not pass the signal on learns that
/// the pipe is done through its pushes alone.
fn stopOf(env: anytype) Stop {
    return if (comptime di.has(@TypeOf(env), Stop)) di.get(env, Stop) else .{};
}

/// The rules of the system this is compiled for.
const native: Dir.path.PathType = switch (@import("builtin").os.tag) {
    .windows => .windows,
    .uefi => .uefi,
    else => .posix,
};

/// `joinAs` by the rules of this system.
fn join(
    comptime max_path_bytes: usize,
    path: *Line(max_path_bytes),
    dir_len: usize,
    name: []const u8,
) error{ PathTooLong, NameTooLong }!void {
    return joinAs(native, max_path_bytes, path, dir_len, name);
}

/// Makes `path` that of `name` in the directory whose own path is its first
/// `dir_len` bytes, as a system with the path rules of `rules` reads paths.
/// A path that `std` would not open by those rules is refused with
/// `error.NameTooLong`, as opening it would refuse it: a walk opens one
/// directory inside another and can go deeper than a path can name, and an
/// entry it gave there would not open. The sources join by the rules of the
/// system they are compiled for. It is public for the tests, which hold the
/// rules of systems they do not run on.
pub fn joinAs(
    comptime rules: Dir.path.PathType,
    comptime max_path_bytes: usize,
    path: *Line(max_path_bytes),
    dir_len: usize,
    name: []const u8,
) error{ PathTooLong, NameTooLong }!void {
    const separated = separates(rules, path.bytes[0..dir_len]);
    const start = dir_len + @intFromBool(separated);
    if (start > max_path_bytes or name.len > max_path_bytes - start) return error.PathTooLong;
    if (separated) path.bytes[dir_len] = if (rules == .posix) Dir.path.sep_posix else Dir.path.sep_windows;
    @memcpy(path.bytes[start..][0..name.len], name);
    path.len = start + name.len;
    if (!opens(rules, path.text())) return error.NameTooLong;
}

/// Whether `std` takes `path` to open by the path rules of `rules`: the
/// directory a source is given is asked before it is opened, and the path
/// of an entry before it is given. On Windows it is converted to UTF-16 in
/// a buffer of `PATH_MAX_WIDE` units that is not checked first, so a path
/// of more units than that is refused here and never given: it would
/// overrun the buffer. A unit takes at least one byte, so a path of no more
/// bytes than that has room. Elsewhere `std` refuses a path of
/// `std.fs.max_path_bytes` bytes or more.
fn opens(comptime rules: Dir.path.PathType, path: []const u8) bool {
    if (rules != .windows) return path.len < Dir.max_path_bytes;
    const room = std.os.windows.PATH_MAX_WIDE;
    return path.len <= room or utf16Units(path) <= room;
}

/// The units of UTF-16 that `path` is: one for each byte that begins a
/// character, and one more for each that begins one of four bytes. It is
/// read byte by byte and not decoded, because the directory a source is
/// given is the caller's and need not be WTF-8: `std`'s own count reads
/// past the end of one cut inside a character. For a path that is not,
/// this is no fewer than `std` writes before it refuses it.
fn utf16Units(path: []const u8) usize {
    var units: usize = 0;
    for (path) |byte| units += @as(usize, @intFromBool(byte & 0xc0 != 0x80)) + @intFromBool(byte >= 0xf0);
    return units;
}

/// Whether a separator goes between the path of a directory and a name in
/// it. None goes after one, and none where it would make the path that of
/// another directory.
fn separates(comptime rules: Dir.path.PathType, dir: []const u8) bool {
    if (dir.len == 0 or rules.isSep(u8, dir[dir.len - 1])) return false;
    if (rules != .windows) return true;
    // A drive alone, `C:`, is the directory the process is in on that drive,
    // and `C:name` is in it. `C:\name` is in the root of the drive.
    const parsed = Dir.path.parsePathWindows(u8, dir);
    return parsed.kind != .drive_relative or parsed.root.len != dir.len;
}

/// What kind of thing `found` is. Some file systems do not say in a listing;
/// the entry is then asked itself, without following a link, so that a
/// directory is never passed by for want of an answer.
fn kindOf(io: Io, dir: Dir, found: Dir.Entry) !Io.File.Kind {
    if (found.kind != .unknown) return found.kind;
    return (try dir.statFile(io, found.name, .{ .follow_symlinks = false })).kind;
}
