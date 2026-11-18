//! Exercise the copy-lines CLI with a destination owned by this test run.
const std = @import("std");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

test "copy-lines copies nonempty lines to a fresh destination" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input.txt", .data = "alpha\n\nbeta\ngamma\n" });

    try expectRun(temp.dir, "output.txt", 0, "copied 3 lines\n", null);
    try expectFile(temp.dir, "output.txt", "alpha\nbeta\ngamma\n");
}

test "copy-lines preserves input when asked to copy it onto itself" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const contents = "keep this input\n";
    try temp.dir.writeFile(io, .{ .sub_path = "input.txt", .data = contents });

    try expectRun(temp.dir, "input.txt", 1, "", "error: PathAlreadyExists");
    try expectFile(temp.dir, "input.txt", contents);
}

fn expectRun(dir: std.Io.Dir, output: []const u8, exit_code: u8, stdout: []const u8, stderr_match: ?[]const u8) !void {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(exe);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ exe, "input.txt", output },
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = exit_code }, result.term);
    try std.testing.expectEqualStrings(stdout, result.stdout);
    if (stderr_match) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
    } else {
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
