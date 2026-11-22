//! Directories as sources: `zrx.ext.fs`.
//!
//! The order of a listing is the system's, so nothing here expects one:
//! what was seen is compared as a set, or the tree is a chain, in which
//! every directory holds one entry and there is only one order.
const std = @import("std");
const builtin = @import("builtin");
const zrx = @import("zrx");
const support = @import("support.zig");
const fs = zrx.ext.fs;

const Io = std.Io;
const Dir = Io.Dir;
const Kind = Io.File.Kind;
const sep = std.fs.path.sep_str;

const program = zrx.program;
const pipe = zrx.pipe;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const take = zrx.take;
const fold = zrx.fold;
const queue = zrx.queue;
const each = zrx.each;
const attempt = zrx.attempt;
const forEach = zrx.forEach;
const compose = zrx.compose;
const field = zrx.field;
const eq = zrx.eq;

const io = std.testing.io;
const allocator = std.testing.allocator;

/// A temporary directory, and the path that opens it from where the tests
/// run: that is what the sources are given.
const Tree = struct {
    tmp: std.testing.TmpDir,
    path_bytes: [path_len]u8,

    const prefix = ".zig-cache" ++ sep ++ "tmp" ++ sep;
    /// Known at compile time, so that a test can choose a bound a path just fits.
    const path_len = prefix.len + @typeInfo(@FieldType(std.testing.TmpDir, "sub_path")).array.len;

    fn init() Tree {
        var tree: Tree = .{ .tmp = std.testing.tmpDir(.{}), .path_bytes = undefined };
        @memcpy(tree.path_bytes[0..prefix.len], prefix);
        @memcpy(tree.path_bytes[prefix.len..], &tree.tmp.sub_path);
        return tree;
    }

    fn deinit(tree: *Tree) void {
        tree.tmp.cleanup();
    }

    fn path(tree: *const Tree) []const u8 {
        return &tree.path_bytes;
    }

    /// The path of the tree with `rest` after it.
    fn with(tree: *const Tree, comptime rest: []const u8) [path_len + rest.len]u8 {
        var out: [path_len + rest.len]u8 = undefined;
        @memcpy(out[0..path_len], &tree.path_bytes);
        @memcpy(out[path_len..], rest);
        return out;
    }

    fn dir(tree: *const Tree, sub_path: []const u8) !void {
        try tree.tmp.dir.createDirPath(io, sub_path);
    }

    fn file(tree: *const Tree, sub_path: []const u8) !void {
        try tree.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
    }
};

const max_path = Tree.path_len + 64;
const Entry = fs.Entry(max_path);

/// What a run delivered, to be compared without regard to order.
fn Seen(comptime T: type) type {
    return struct {
        log: support.Recorder(T) = .{},

        fn note(seen: *@This(), entry: T) void {
            seen.log.add(entry);
        }

        /// The path of an entry below the directory the source was given.
        fn below(tree: *const Tree, entry: *const T) ![]const u8 {
            const text = entry.path.text();
            try std.testing.expectStringStartsWith(text, tree.path());
            try std.testing.expectStringStartsWith(text[Tree.path_len..], sep);
            return text[Tree.path_len + sep.len ..];
        }

        /// Exactly these entries were seen, each once, in any order.
        fn expect(seen: *const @This(), tree: *const Tree, expected: []const struct { []const u8, Kind }) !void {
            try std.testing.expectEqual(expected.len, seen.log.len);
            for (expected) |wanted| {
                var found: usize = 0;
                for (seen.log.slice()) |*entry| {
                    if (!std.mem.eql(u8, wanted[0], try below(tree, entry))) continue;
                    try std.testing.expectEqual(wanted[1], entry.kind);
                    found += 1;
                }
                try std.testing.expectEqual(1, found);
            }
        }
    };
}

/// `std.testing.io`, counting the directories a run opens and closes, and
/// able to stand in for a file system that is not at hand.
const Dirs = struct {
    var vtable: Io.VTable = undefined;
    var inner: Io = undefined;
    var options: Options = .{};
    var opened: std.atomic.Value(usize) = .init(0);
    var closed: std.atomic.Value(usize) = .init(0);
    /// How many times a listing was asked for its next entry.
    var reads: std.atomic.Value(usize) = .init(0);

    const Options = struct {
        /// The name of a directory that cannot be opened.
        refused: ?[]const u8 = null,
        /// A listing does not say what kind an entry is, as on some file systems.
        kinds_unknown: bool = false,
        /// A listing never ends: it holds the file `x` again and again.
        endless: bool = false,
        /// A listing calls a symbolic link a directory, as it would have
        /// been right to before the one was put in the place of the other.
        links_as_directories: bool = false,
    };

    fn init(given: Options) Io {
        inner = io;
        options = given;
        opened.store(0, .monotonic);
        closed.store(0, .monotonic);
        reads.store(0, .monotonic);
        vtable = inner.vtable.*;
        vtable.dirOpenDir = open;
        vtable.dirClose = close;
        vtable.dirRead = read;
        return .{ .userdata = inner.userdata, .vtable = &vtable };
    }

    fn open(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, given: Dir.OpenOptions) Dir.OpenError!Dir {
        if (options.refused) |name| if (std.mem.eql(u8, name, std.fs.path.basename(sub_path))) return error.AccessDenied;
        const result = try inner.vtable.dirOpenDir(userdata, dir, sub_path, given);
        _ = opened.fetchAdd(1, .monotonic);
        return result;
    }

    fn close(userdata: ?*anyopaque, dirs: []const Dir) void {
        _ = closed.fetchAdd(dirs.len, .monotonic);
        inner.vtable.dirClose(userdata, dirs);
    }

    fn read(userdata: ?*anyopaque, reader: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
        _ = reads.fetchAdd(1, .monotonic);
        if (options.endless) {
            buffer[0] = .{ .name = "x", .kind = .file, .inode = 0 };
            return 1;
        }
        const count = try inner.vtable.dirRead(userdata, reader, buffer);
        if (options.kinds_unknown) for (buffer[0..count]) |*entry| {
            entry.kind = .unknown;
        };
        if (options.links_as_directories) for (buffer[0..count]) |*entry| {
            if (entry.kind == .sym_link) entry.kind = .directory;
        };
        return count;
    }

    /// The run opened this many directories and has closed every one.
    fn expectClosed(count: usize) !void {
        try std.testing.expectEqual(count, opened.load(.monotonic));
        try std.testing.expectEqual(count, closed.load(.monotonic));
    }
};

const note = Seen(Entry).note;
const isFile = compose(.{ field(.kind), eq(.file) });
const isDirectory = compose(.{ field(.kind), eq(.directory) });

// ---------------------------------------------------------------------------
// entries
// ---------------------------------------------------------------------------

test "an empty directory has no entries" {
    var tree: Tree = .init();
    defer tree.deinit();
    var seen: Seen(Entry) = .{};
    const counting = Dirs.init(.{});
    try support.run(program(fs.entries(tree.path(), max_path), .{forEach(note)}), .{ counting, &seen });
    try seen.expect(&tree, &.{});
    try support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ counting, allocator, &seen });
    try seen.expect(&tree, &.{});
    try Dirs.expectClosed(2);
}

test "entries are those of the one directory, each with its kind" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.file("a.txt");
    try tree.file("b.txt");
    try tree.dir("sub");
    try tree.file("sub/inner.txt");

    var seen: Seen(Entry) = .{};
    try support.run(program(fs.entries(tree.path(), max_path), .{forEach(note)}), .{ Dirs.init(.{}), &seen });
    try seen.expect(&tree, &.{ .{ "a.txt", .file }, .{ "b.txt", .file }, .{ "sub", .directory } });
    try Dirs.expectClosed(1);
}

test "a filter on the kind keeps files, and an entry says its name" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.file("a.txt");
    try tree.dir("sub");
    try tree.file("sub/inner.txt");

    var files: Seen(Entry) = .{};
    try support.run(program(fs.walk(tree.path(), max_path), .{ filter(isFile), forEach(note) }), .{ io, allocator, &files });
    try files.expect(&tree, &.{ .{ "a.txt", .file }, .{ "sub" ++ sep ++ "inner.txt", .file } });
    for (files.log.slice()) |*entry| {
        const name = entry.name();
        try std.testing.expect(std.mem.eql(u8, name, "a.txt") or std.mem.eql(u8, name, "inner.txt"));
    }

    var directories: Seen(Entry) = .{};
    try support.run(program(fs.walk(tree.path(), max_path), .{ filter(isDirectory), forEach(note) }), .{ io, allocator, &directories });
    try directories.expect(&tree, &.{.{ "sub", .directory }});
}

test "a directory given with its separator is not given a second one" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.file("a.txt");

    const given = tree.with(sep);
    var seen: Seen(Entry) = .{};
    try support.run(program(fs.entries(&given, max_path), .{forEach(note)}), .{ io, &seen });
    try seen.expect(&tree, &.{.{ "a.txt", .file }});
}

test "a directory that is not there fails the run with what the system said" {
    var tree: Tree = .init();
    defer tree.deinit();
    const missing = tree.with(sep ++ "missing");

    var seen: Seen(Entry) = .{};
    const counting = Dirs.init(.{});
    try std.testing.expectError(error.FileNotFound, support.run(program(fs.entries(&missing, max_path), .{forEach(note)}), .{ counting, &seen }));
    try std.testing.expectError(error.FileNotFound, support.run(program(fs.walk(&missing, max_path), .{forEach(note)}), .{ counting, allocator, &seen }));
    try seen.expect(&tree, &.{});
    try Dirs.expectClosed(0);
}

test "a source keeps the path it was given" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.file("a.txt");

    var given = tree.path_bytes;
    const listed = program(fs.entries(&given, max_path), .{forEach(note)});
    const walked = program(fs.walk(&given, max_path), .{forEach(note)});
    @memset(&given, '?');

    var seen: Seen(Entry) = .{};
    try support.run(listed, .{ io, &seen });
    try support.run(walked, .{ io, allocator, &seen });
    try std.testing.expectEqual(2, seen.log.len);
    for (seen.log.slice()) |*entry| try std.testing.expectEqualStrings("a.txt", try Seen(Entry).below(&tree, entry));
}

// ---------------------------------------------------------------------------
// walk
// ---------------------------------------------------------------------------

/// A tree with files and directories on three levels, an empty directory among them.
const nested = [_]struct { []const u8, Kind }{
    .{ "top.txt", .file },
    .{ "empty", .directory },
    .{ "a", .directory },
    .{ "a" ++ sep ++ "one.txt", .file },
    .{ "a" ++ sep ++ "two.txt", .file },
    .{ "a" ++ sep ++ "b", .directory },
    .{ "a" ++ sep ++ "b" ++ sep ++ "deep.txt", .file },
    .{ "c", .directory },
    .{ "c" ++ sep ++ "three.txt", .file },
};

fn plant(tree: *const Tree) !void {
    for (nested) |entry| if (entry[1] == .directory) try tree.dir(entry[0]);
    for (nested) |entry| if (entry[1] == .file) try tree.file(entry[0]);
}

test "walk gives every entry under a directory, however deep" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    var seen: Seen(Entry) = .{};
    try support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ Dirs.init(.{}), allocator, &seen });
    try seen.expect(&tree, &nested);
    // The directory itself and the four below it.
    try Dirs.expectClosed(5);
}

test "walk gives a directory before what is in it" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    var seen: Seen(Entry) = .{};
    try support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ io, allocator, &seen });
    for (seen.log.slice(), 0..) |*entry, at| {
        const parent = std.fs.path.dirname(entry.path.text()).?;
        if (std.mem.eql(u8, parent, tree.path())) continue;
        var before = false;
        for (seen.log.slice()[0..at]) |*earlier| {
            if (std.mem.eql(u8, earlier.path.text(), parent)) before = true;
        }
        try std.testing.expect(before);
    }
}

test "an entry holds its path across a queue" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    var seen: Seen(Entry) = .{};
    try support.run(program(fs.walk(tree.path(), max_path), .{ queue(2), forEach(note) }), .{ io, allocator, &seen });
    try seen.expect(&tree, &nested);
}

test "a listing that does not say what an entry is does not hide a directory" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    var seen: Seen(Entry) = .{};
    const silent = Dirs.init(.{ .kinds_unknown = true });
    try support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ silent, allocator, &seen });
    try seen.expect(&tree, &nested);

    var top: Seen(Entry) = .{};
    try support.run(program(fs.entries(tree.path(), max_path), .{forEach(note)}), .{ silent, &top });
    try top.expect(&tree, &.{ .{ "top.txt", .file }, .{ "empty", .directory }, .{ "a", .directory }, .{ "c", .directory } });
}

test "a symbolic link is an entry and is not followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.dir("real");
    try tree.file("real/inner.txt");
    try tree.tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });
    // A link to the directory it is in would never end if it were followed.
    try tree.tmp.dir.symLink(io, ".", "real/around", .{ .is_directory = true });
    try tree.tmp.dir.symLink(io, "nowhere", "dangling", .{});

    const expected = [_]struct { []const u8, Kind }{
        .{ "real", .directory },
        .{ "real" ++ sep ++ "inner.txt", .file },
        .{ "real" ++ sep ++ "around", .sym_link },
        .{ "link", .sym_link },
        .{ "dangling", .sym_link },
    };
    inline for (.{ false, true }) |kinds_unknown| {
        var seen: Seen(Entry) = .{};
        const counting = Dirs.init(.{ .kinds_unknown = kinds_unknown });
        try support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ counting, allocator, &seen });
        try seen.expect(&tree, &expected);
        try Dirs.expectClosed(2);
    }
}

test "a directory that has become a symbolic link fails the walk and is not gone into" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.dir("real");
    try tree.file("real/inner.txt");
    try tree.tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    var seen: Seen(Entry) = .{};
    const counting = Dirs.init(.{ .links_as_directories = true });
    const result = support.run(program(fs.walk(tree.path(), max_path), .{ filter(isFile), forEach(note) }), .{ counting, allocator, &seen });
    // Which of the two is the system's choice.
    if (result) |_| return error.FollowedLink else |err| switch (err) {
        error.SymLinkLoop, error.NotDir => {},
        else => return err,
    }
    // Before or after `real`, as the listing has it: never twice.
    try std.testing.expect(seen.log.len <= 1);
    try std.testing.expectEqual(Dirs.opened.load(.monotonic), Dirs.closed.load(.monotonic));
}

test "the directory a walk is given may be a symbolic link" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.dir("real");
    try tree.file("real/inner.txt");
    try tree.tmp.dir.symLink(io, "real", "link", .{ .is_directory = true });

    const given = tree.with(sep ++ "link");
    var seen: Seen(Entry) = .{};
    try support.run(program(fs.walk(&given, max_path), .{forEach(note)}), .{ io, allocator, &seen });
    try seen.expect(&tree, &.{.{ "link" ++ sep ++ "inner.txt", .file }});
}

// ---------------------------------------------------------------------------
// stopping
// ---------------------------------------------------------------------------

/// Directories that hold one entry each, so that there is one order to walk them in.
const chain = "a" ++ sep ++ "b" ++ sep ++ "c" ++ sep ++ "d";

/// What a walk of the chain gives, in the order it gives it.
const chained = [_]struct { []const u8, Kind }{
    .{ "a", .directory },
    .{ "a" ++ sep ++ "b", .directory },
    .{ "a" ++ sep ++ "b" ++ sep ++ "c", .directory },
    .{ chain, .directory },
    .{ chain ++ sep ++ "end.txt", .file },
};

fn plantChain(tree: *const Tree) !void {
    try tree.dir(chain);
    try tree.file(chain ++ sep ++ "end.txt");
}

test "a pipe that is done ends the walk, and every directory it was in is closed" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plantChain(&tree);

    inline for (.{ 1, 2, 3, 5 }) |count| {
        var seen: Seen(Entry) = .{};
        try support.run(program(fs.walk(tree.path(), max_path), .{ take(count), forEach(note) }), .{ Dirs.init(.{}), allocator, &seen });
        try seen.expect(&tree, chained[0..count]);
        // A directory is an item before it is opened: the one the pipe was
        // done with has not been.
        try Dirs.expectClosed(count);
        // Nor was anything read after it.
        try std.testing.expectEqual(count, Dirs.reads.load(.monotonic));
    }
}

test "a pipe that is done ends the entries of a directory" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    var seen: Seen(Entry) = .{};
    try support.run(program(fs.entries(tree.path(), max_path), .{ take(2), forEach(note) }), .{ Dirs.init(.{}), &seen });
    try std.testing.expectEqual(2, seen.log.len);
    try std.testing.expectEqual(2, Dirs.reads.load(.monotonic));
    try Dirs.expectClosed(1);
}

const Passed = struct { count: usize = 0 };

/// True for the first entry alone: after it, no push tells the source anything.
fn firstOnly(passed: *Passed, _: Entry) bool {
    passed.count += 1;
    return passed.count == 1;
}

test "a source nothing more is wanted of ends without a push to tell it so" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.dir("sub");

    // Neither listing ends, and the filter lets nothing through after the
    // first entry: only the signal of the run ends these sources.
    const endless = Dirs.init(.{ .endless = true });
    const once = pipe(.{ filter(firstOnly), queue(1), take(1), forEach(note) });
    {
        var seen: Seen(Entry) = .{};
        var passed: Passed = .{};
        try support.run(program(fs.entries(tree.path(), max_path), once), .{ endless, &seen, &passed });
        try seen.expect(&tree, &.{.{ "x", .file }});
    }
    {
        var seen: Seen(Entry) = .{};
        var passed: Passed = .{};
        try support.run(program(fs.walk(tree.path(), max_path), once), .{ endless, allocator, &seen, &passed });
        try seen.expect(&tree, &.{.{ "x", .file }});
    }
}

// ---------------------------------------------------------------------------
// what fails
// ---------------------------------------------------------------------------

test "a path that just fits is given, and one byte more fails the run" {
    var tree: Tree = .init();
    defer tree.deinit();
    try tree.file("abcd");

    const fits = Tree.path_len + sep.len + "abcd".len;
    inline for (.{ fs.entries, fs.walk }) |source| {
        var seen: Seen(fs.Entry(fits)) = .{};
        try support.run(program(source(tree.path(), fits), .{forEach(Seen(fs.Entry(fits)).note)}), .{ io, allocator, &seen });
        try seen.expect(&tree, &.{.{ "abcd", .file }});

        var none: Seen(fs.Entry(fits - 1)) = .{};
        const counting = Dirs.init(.{});
        try std.testing.expectError(
            error.PathTooLong,
            support.run(program(source(tree.path(), fits - 1), .{forEach(Seen(fs.Entry(fits - 1)).note)}), .{ counting, allocator, &none }),
        );
        try none.expect(&tree, &.{});
        try Dirs.expectClosed(1);
    }
}

test "a path too long further down fails the walk after what fitted" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plantChain(&tree);

    // Room for `a/b/c` and no more.
    const bound = Tree.path_len + sep.len + "a/b/c".len;
    var seen: Seen(fs.Entry(bound)) = .{};
    const counting = Dirs.init(.{});
    try std.testing.expectError(
        error.PathTooLong,
        support.run(program(fs.walk(tree.path(), bound), .{forEach(Seen(fs.Entry(bound)).note)}), .{ counting, allocator, &seen }),
    );
    try seen.expect(&tree, chained[0..3]);
    try Dirs.expectClosed(4);
}

test "a directory whose own path is too long fails the run before it is opened" {
    var tree: Tree = .init();
    defer tree.deinit();

    var seen: Seen(fs.Entry(Tree.path_len - 1)) = .{};
    const noteShort = Seen(fs.Entry(Tree.path_len - 1)).note;
    const counting = Dirs.init(.{});
    try std.testing.expectError(
        error.PathTooLong,
        support.run(program(fs.entries(tree.path(), Tree.path_len - 1), .{forEach(noteShort)}), .{ counting, &seen }),
    );
    try std.testing.expectError(
        error.PathTooLong,
        support.run(program(fs.walk(tree.path(), Tree.path_len - 1), .{forEach(noteShort)}), .{ counting, allocator, &seen }),
    );
    try Dirs.expectClosed(0);
}

test "a directory that cannot be opened fails the walk, after it was given as an entry" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plantChain(&tree);

    var seen: Seen(Entry) = .{};
    const counting = Dirs.init(.{ .refused = "c" });
    try std.testing.expectError(
        error.AccessDenied,
        support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ counting, allocator, &seen }),
    );
    try seen.expect(&tree, chained[0..3]);
    try Dirs.expectClosed(3);
}

test "a walk that cannot allocate fails the run and leaves nothing open" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plantChain(&tree);

    // Every allocation the whole walk makes fails in turn.
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = fail_at });
        var seen: Seen(Entry) = .{};
        const counting = Dirs.init(.{});
        const result = support.run(program(fs.walk(tree.path(), max_path), .{forEach(note)}), .{ counting, failing.allocator(), &seen });
        try std.testing.expectEqual(Dirs.opened.load(.monotonic), Dirs.closed.load(.monotonic));
        if (!failing.has_induced_failure) {
            try result;
            try std.testing.expectEqual(5, seen.log.len);
            break;
        }
        try std.testing.expectError(error.OutOfMemory, result);
    }
    try std.testing.expect(fail_at > 0);
}

// ---------------------------------------------------------------------------
// one directory for one item
// ---------------------------------------------------------------------------

fn listing(path: []const u8) fs.Entries(max_path) {
    return fs.entries(path, max_path);
}

fn under(path: []const u8) fs.Walk(max_path) {
    return fs.walk(path, max_path);
}

fn tally(sum: usize, _: Entry) usize {
    return sum + 1;
}

/// How many entries a directory has, or that it could not be listed.
const Counted = struct { path: []const u8, entries: ?usize };

fn counted(directory: zrx.Tagged([]const u8, usize)) Counted {
    return .{ .path = directory.source, .entries = directory.item };
}

fn unlisted(failure: zrx.Failed(error{FileNotFound}, []const u8)) Counted {
    return .{ .path = failure.item, .entries = null };
}

test "a directory listed for one item fails that item, which an error path takes" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    const a = tree.with(sep ++ "a");
    const missing = tree.with(sep ++ "missing");
    const c = tree.with(sep ++ "c");
    const paths = [_][]const u8{ &a, &missing, &c };
    inline for (.{ .{ listing, 3 }, .{ under, 4 } }) |case| {
        const sized = pipe(.{
            each(case[0], .{fold(@as(usize, 0), tally)}),
            map(counted),
        });
        var seen: support.Recorder(Counted) = .{};
        try support.run(program(fromSlice(&paths), .{
            attempt(sized, error{FileNotFound}, .{map(unlisted)}),
            forEach(support.record(Counted)),
        }), .{ Dirs.init(.{}), allocator, &seen });
        try std.testing.expectEqual(3, seen.len);
        try std.testing.expectEqual(case[1], seen.items[0].entries);
        try std.testing.expectEqual(null, seen.items[1].entries);
        try std.testing.expectEqualStrings(paths[1], seen.items[1].path);
        try std.testing.expectEqual(1, seen.items[2].entries);
        try std.testing.expectEqual(Dirs.opened.load(.monotonic), Dirs.closed.load(.monotonic));
    }
}

fn listingOf(directory: Entry) fs.Entries(max_path) {
    return fs.entries(directory.path.text(), max_path);
}

fn underOf(directory: Entry) fs.Walk(max_path) {
    return fs.walk(directory.path.text(), max_path);
}

/// How many entries a directory of a walk has, or that it could not be opened.
const Sized = struct { directory: Entry, entries: ?usize };

fn sizedOf(directory: zrx.Tagged(Entry, usize)) Sized {
    return .{ .directory = directory.source, .entries = directory.item };
}

fn refused(failure: zrx.Failed(error{AccessDenied}, Entry)) Sized {
    return .{ .directory = failure.item, .entries = null };
}

test "the directories among the entries are listed each as an item, and one that cannot be is that item's failure" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    inline for (.{ .{ listingOf, 3 }, .{ underOf, 4 } }) |case| {
        const sized = pipe(.{
            each(case[0], .{fold(@as(usize, 0), tally)}),
            map(sizedOf),
        });
        var seen: support.Recorder(Sized) = .{};
        try support.run(program(fs.entries(tree.path(), max_path), .{
            filter(isDirectory),
            attempt(sized, error{AccessDenied}, .{map(refused)}),
            forEach(support.record(Sized)),
        }), .{ Dirs.init(.{ .refused = "c" }), allocator, &seen });

        try std.testing.expectEqual(3, seen.len);
        for (seen.slice()) |*sized_directory| {
            const expected: ?usize = if (std.mem.eql(u8, sized_directory.directory.name(), "a"))
                case[1]
            else if (std.mem.eql(u8, sized_directory.directory.name(), "empty"))
                0
            else
                null;
            try std.testing.expectEqual(expected, sized_directory.entries);
        }
        try std.testing.expectEqual(Dirs.opened.load(.monotonic), Dirs.closed.load(.monotonic));
    }
}

// ---------------------------------------------------------------------------
// the guide
// ---------------------------------------------------------------------------

const Listing = struct { writer: *Io.Writer };

test "the guide's example lists the files under a directory" {
    var tree: Tree = .init();
    defer tree.deinit();
    try plant(&tree);

    const files = program(fs.walk(tree.path(), max_path), .{
        filter(isFile),
        map(field(.path)),
        zrx.write(Listing, "{f}\n"),
    });
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try support.run(files, .{ io, allocator, Listing{ .writer = &writer } });

    var lines: usize = 0;
    var written = std.mem.tokenizeScalar(u8, writer.buffered(), '\n');
    while (written.next()) |line| : (lines += 1) {
        try std.testing.expectStringStartsWith(line, tree.path());
        var known = false;
        for (nested) |entry| {
            if (entry[1] == .file and std.mem.eql(u8, line[Tree.path_len + sep.len ..], entry[0])) known = true;
        }
        try std.testing.expect(known);
    }
    try std.testing.expectEqual(5, lines);
}
