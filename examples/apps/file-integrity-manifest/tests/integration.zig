const std = @import("std");
const app = @import("app");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn invoke(dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stdout: []const u8, stderr: []const u8) !void {
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
    try std.testing.expectEqualStrings(stdout, result.stdout);
    try std.testing.expectEqualStrings(stderr, result.stderr);
}

const good = "{\"index\":1,\"path\":\"abc\",\"bytes\":3,\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}";
const duplicate = "{\"index\":4,\"path\":\"abc\",\"bytes\":3,\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}";
const missing = "{\"index\":2,\"path\":\"missing\",\"error\":\"FileNotFound\"}";
const directory = "{\"index\":3,\"path\":\".\",\"error\":\"NotRegularFile\"}";

fn expectResults(actual: []const u8, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, actual, '\n');
    var seen: [8]bool = @splat(false);
    try std.testing.expect(expected.len <= seen.len);
    for (0..expected.len) |_| {
        const line = lines.next() orelse return error.MissingLine;
        for (expected, 0..) |want, i| {
            if (std.mem.eql(u8, want, line)) {
                try std.testing.expect(!seen[i]);
                seen[i] = true;
                break;
            }
        } else return error.UnexpectedLine;
    }
    try std.testing.expectEqualStrings("", lines.next() orelse return error.MissingNewline);
    try std.testing.expectEqual(null, lines.next());
}

test "the composition injects its directory and returns per-file errors" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    var bytes: [1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&bytes);
    try std.testing.expectEqual(@as(usize, 2), try app.generate(io, .{ .dir = temp.dir }, &.{ "abc", "missing", ".", "abc" }, &output));
    try expectResults(output.buffered(), &.{ good, missing, directory, duplicate });
}

test "the executable publishes a manifest and returns partial success" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    try invoke(temp.dir, &.{ "manifest", "abc", "missing", "." }, 1, "", "");
    const result = try temp.dir.readFileAlloc(io, "manifest", allocator, .limited(1024));
    defer allocator.free(result);
    try expectResults(result, &.{ good, missing, directory });

    try invoke(temp.dir, &.{ "manifest", "abc" }, 2, "", "fatal: PathAlreadyExists\n");
    const unchanged = try temp.dir.readFileAlloc(io, "manifest", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(result, unchanged);
}
