const std = @import("std");
const zrx = @import("zrx");
const app = @import("app");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const abc_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// Runs the executable in `dir` and checks how it ended and what it printed.
fn invoke(dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stderr: []const u8) !void {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.appendSlice(allocator, args);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = expected_exit }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
}

/// The workers finish in any order: `actual` holds exactly the `expected`
/// rows, each on a line of its own, in some order.
fn expectRows(actual: []const u8, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, actual, '\n');
    var seen: [8]bool = @splat(false);
    try std.testing.expect(expected.len <= seen.len);
    for (0..expected.len) |_| {
        const line = lines.next() orelse return error.MissingLine;
        for (expected, 0..) |want, i| {
            if (!seen[i] and std.mem.eql(u8, want, line)) {
                seen[i] = true;
                break;
            }
        } else {
            std.debug.print("unexpected row: {s}\n", .{line});
            return error.UnexpectedLine;
        }
    }
    try std.testing.expectEqualStrings("", lines.next() orelse return error.MissingNewline);
    try std.testing.expectEqual(null, lines.next());
}

fn expectManifest(dir: std.Io.Dir, expected: []const []const u8) !void {
    const rows = try dir.readFileAlloc(io, "manifest", allocator, .limited(4096));
    defer allocator.free(rows);
    try expectRows(rows, expected);
}

/// A path the app can open: it resolves paths against the working directory,
/// and that is where the test's temporary directory lives.
fn pathIn(arena: std.mem.Allocator, temp: *const std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}{s}{s}", .{ temp.sub_path, if (name.len == 0) "" else "/", name });
}

/// Runs the app's pipe over `paths` into `output` and returns the outcome it stored.
fn manifestOf(paths: []const []const u8, output: *std.Io.Writer) !app.Exit {
    var exit: app.Exit = .complete;
    try zrx.program(zrx.fromSlice(paths), app.manifest).run(.{ io, &exit, app.Manifest{ .writer = output } });
    return exit;
}

test "the pipe writes a row per path and stores the outcome" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try pathIn(arena, &temp, "");
    const abc = try pathIn(arena, &temp, "abc");
    const missing = try pathIn(arena, &temp, "missing");
    const good_row = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"bytes\":3,\"sha256\":\"{s}\"}}", .{ abc, abc_sha256 });

    var bytes: [2048]u8 = undefined;
    var output: std.Io.Writer = .fixed(&bytes);
    // More paths than workers, and one of them several times.
    const exit = try manifestOf(&.{ abc, missing, root, abc, abc, abc }, &output);

    try std.testing.expectEqual(app.Exit.incomplete, exit);
    try expectRows(output.buffered(), &.{
        good_row,
        try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"failure\":\"FileNotFound\"}}", .{missing}),
        try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"failure\":\"IsDir\"}}", .{root}),
        good_row,
        good_row,
        good_row,
    });
}

test "a file larger than what a worker reads at a time is hashed whole" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var data: [3 * app.read_bytes + 3]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = "abc"[i % 3];
    try temp.dir.writeFile(io, .{ .sub_path = "data", .data = &data });
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try pathIn(arena, &temp, "data");

    var bytes: [1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&bytes);
    try std.testing.expectEqual(app.Exit.complete, try manifestOf(&.{path}, &output));

    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&data, &expected, .{});
    try expectRows(output.buffered(), &.{
        try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"bytes\":{d},\"sha256\":\"{s}\"}}", .{ path, data.len, std.fmt.bytesToHex(expected, .lower) }),
    });
}

const abc_row = "{\"path\":\"abc\",\"bytes\":3,\"sha256\":\"" ++ abc_sha256 ++ "\"}";
const empty_row = "{\"path\":\"empty\",\"bytes\":0,\"sha256\":\"" ++ empty_sha256 ++ "\"}";
const missing_row = "{\"path\":\"missing\",\"failure\":\"FileNotFound\"}";
const directory_row = "{\"path\":\".\",\"failure\":\"IsDir\"}";

test "the executable exits 0 when every file was hashed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    try temp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try invoke(temp.dir, &.{ "manifest", "abc", "empty" }, 0, "");
    try expectManifest(temp.dir, &.{ abc_row, empty_row });
}

test "the executable exits 1 with a complete manifest when files failed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    try invoke(temp.dir, &.{ "manifest", "abc", "missing", "." }, 1, "");
    try expectManifest(temp.dir, &.{ abc_row, missing_row, directory_row });
}

test "a named pipe gets a failure row instead of holding up the manifest" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    // Nobody writes to it: opening it would wait for as long as the test does.
    const made = try std.process.run(allocator, io, .{ .argv = &.{ "mkfifo", "pipe" }, .cwd = .{ .dir = temp.dir } });
    defer allocator.free(made.stdout);
    defer allocator.free(made.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);
    try invoke(temp.dir, &.{ "manifest", "abc", "pipe" }, 1, "");
    try expectManifest(temp.dir, &.{ abc_row, "{\"path\":\"pipe\",\"failure\":\"NotRegularFile\"}" });
}

test "the executable exits 2 and keeps an output path that exists" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    try temp.dir.writeFile(io, .{ .sub_path = "manifest", .data = "earlier\n" });
    try invoke(temp.dir, &.{ "manifest", "abc" }, 2, "fatal: PathAlreadyExists\n");
    try expectManifest(temp.dir, &.{"earlier"});
}

test "the executable exits 2 without files to hash and writes nothing" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try invoke(temp.dir, &.{"manifest"}, 2, "fatal: InvalidArguments\n");
    try invoke(temp.dir, &.{}, 2, "fatal: InvalidArguments\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.access(io, "manifest", .{}));
}
