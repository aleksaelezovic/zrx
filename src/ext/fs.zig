//! Directories as sources, on top of `std.Io.Dir`.
//!
//!     const sources = program(fs.walk("src", 512), .{
//!         filter(isZigFile),
//!         map(field(.path)),
//!         print(Stdout, "{f}\n"),
//!     });
//!
//! `entries` gives the entries of one directory and `walk` those under it,
//! however deep. A directory is named by its path, as a file is for
//! `fileLines`: it is opened when the source runs and closed when the source
//! ends, whichever way it ends. An item holds its path, so it may cross a
//! `queue`; the path begins with the directory's as it was given, so it
//! opens with whatever opens a path. A source holds its directory's path
//! too, so one may be made from an entry: `each(listing, ...)` lists the
//! directories a walk found, each as an item of its own.
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
/// `error.PathTooLong`, the directory's own included. `path` is copied: it
/// need not outlive this call. Needs `std.Io`.
pub fn entries(path: []const u8, comptime max_path_bytes: usize) Entries(max_path_bytes) {
    return .{ .path = Line(max_path_bytes).from(path) catch null };
}

/// The type of `entries(path, max_path_bytes)`, for a handler that returns one.
pub fn Entries(comptime max_path_bytes: usize) type {
    expectRoom("fs.entries", max_path_bytes);
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

/// The entries under the directory at `path`, however deep, without `.` and
/// `..`. A directory is an entry, and comes before what is in it; beyond
/// that the order is the system's. A symbolic link is an entry and is not
/// followed. A path longer than `max_path_bytes` fails the run with
/// `error.PathTooLong`, and a directory that cannot be opened or read fails
/// it with what the system reported: nothing is left out silently.
///
/// `path` is copied: it need not outlive this call. Needs `std.Io`, and
/// `std.mem.Allocator` for the directories it is inside of: one listing for
/// each level it has gone down, freed when the walk ends. Nothing is
/// allocated for an entry.
pub fn walk(path: []const u8, comptime max_path_bytes: usize) Walk(max_path_bytes) {
    return .{ .path = Line(max_path_bytes).from(path) catch null };
}

/// The type of `walk(path, max_path_bytes)`, for a handler that returns one.
pub fn Walk(comptime max_path_bytes: usize) type {
    expectRoom("fs.walk", max_path_bytes);
    return struct {
        /// The directory, or null when its own path is too long.
        path: ?Line(max_path_bytes),

        pub const zrx_source = {};
        pub const zrx_stop_source = true;
        pub const Item = Entry(max_path_bytes);

        /// A directory the walk is inside of. `std`'s walker keeps the same,
        /// but its `deinit` leaves the directories open when the walk ends
        /// before the listing does, which here is every early stop.
        const Level = struct {
            listing: Dir.Iterator,
            /// How much of the path is this directory's.
            path_len: usize,
        };

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            comptime expectIo("fs.walk", @TypeOf(env));
            comptime if (!di.has(@TypeOf(env), std.mem.Allocator)) @compileError(
                "fs.walk: needs `std.mem.Allocator` for the directories it is inside of; pass an allocator to `run(.{ io, allocator, ... })`",
            );
            const io = di.get(env, Io);
            const allocator = di.get(env, std.mem.Allocator);
            const stop = stopOf(env);
            var path = self.path orelse return error.PathTooLong;

            var levels: std.ArrayList(Level) = .empty;
            defer {
                for (levels.items) |level| level.listing.reader.dir.close(io);
                levels.deinit(allocator);
            }
            try levels.ensureUnusedCapacity(allocator, 1);
            const root = try Dir.cwd().openDir(io, path.text(), .{ .iterate = true });
            levels.appendAssumeCapacity(.{ .listing = root.iterateAssumeFirstIteration(), .path_len = path.len });

            while (levels.items.len != 0 and !stop.requested()) {
                // Before the name is read: it lies in the listing, which
                // lies in this list.
                try levels.ensureUnusedCapacity(allocator, 1);
                const top = &levels.items[levels.items.len - 1];
                const dir = top.listing.reader.dir;
                const found = try top.listing.next(io) orelse {
                    dir.close(io);
                    levels.items.len -= 1;
                    continue;
                };
                try join(max_path_bytes, &path, top.path_len, found.name);
                const kind = try kindOf(io, dir, found);
                // The directory is an item before it is opened: a pipe that
                // is done with it does not have it opened.
                if (try down.push(Item{ .path = path, .kind = kind }) == .done) return;
                if (kind != .directory) continue;
                // Not through a link, if the name has become one since it was listed.
                const below = try dir.openDir(io, found.name, .{ .iterate = true, .follow_symlinks = false });
                levels.appendAssumeCapacity(.{ .listing = below.iterateAssumeFirstIteration(), .path_len = path.len });
            }
        }
    };
}

fn expectRoom(comptime who: []const u8, comptime max_path_bytes: usize) void {
    if (max_path_bytes == 0) @compileError(
        who ++ ": a path needs room for at least one byte; pass a positive comptime size such as `" ++ who ++ "(path, 1024)`",
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

/// Makes `path` that of `name` in the directory whose own path is its first `dir_len` bytes.
fn join(comptime max_path_bytes: usize, path: *Line(max_path_bytes), dir_len: usize, name: []const u8) error{PathTooLong}!void {
    const separated = dir_len != 0 and !Dir.path.isSep(path.bytes[dir_len - 1]);
    const start = dir_len + @intFromBool(separated);
    if (start > max_path_bytes or name.len > max_path_bytes - start) return error.PathTooLong;
    if (separated) path.bytes[dir_len] = Dir.path.sep;
    @memcpy(path.bytes[start..][0..name.len], name);
    path.len = start + name.len;
}

/// What kind of thing `found` is. Some file systems do not say in a listing;
/// the entry is then asked itself, without following a link, so that a
/// directory is never passed by for want of an answer.
fn kindOf(io: Io, dir: Dir, found: Dir.Entry) !Io.File.Kind {
    if (found.kind != .unknown) return found.kind;
    return (try dir.statFile(io, found.name, .{ .follow_symlinks = false })).kind;
}
