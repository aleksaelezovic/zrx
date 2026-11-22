//! Directories as sources, on top of `std.Io.Dir`.
//!
//!     const sources = program(fs.walk("src", 512, 16), .{
//!         filter(isZigFile),
//!         map(field(.path)),
//!         print(Stdout, "{f}\n"),
//!     });
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
//! Nothing here allocates: the longest path and the depth of a walk are
//! written where the source is made, and what does not fit fails the run
//! with an error of its own name.
//!
//! Nothing here is known to the core: both are sources like any other.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const di = @import("../di.zig");
const Line = @import("../io.zig").Line;
const Stop = @import("../completion.zig").Stop;

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

/// Whether `std` takes `path` to open by the path rules of `rules`. On
/// Windows it is converted to UTF-16 in a buffer of `PATH_MAX_WIDE` units
/// that is not checked first, so a path of more units than that is refused
/// here and never given: it would overrun the buffer. A unit takes at least
/// one byte, so a path of no more bytes than that has room. Elsewhere `std`
/// refuses a path of `std.fs.max_path_bytes` bytes or more.
fn opens(comptime rules: Dir.path.PathType, path: []const u8) bool {
    if (rules != .windows) return path.len < Dir.max_path_bytes;
    const room = std.os.windows.PATH_MAX_WIDE;
    if (path.len <= room) return true;
    const units = std.unicode.calcWtf16LeLen(path) catch return false;
    return units <= room;
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
