const std = @import("std");
const options = @import("options");
const domain = @import("domain");
const app = @import("app");
const plain = @import("plain");
const io = std.testing.io;
const alloc = std.testing.allocator;

const sample = "Z;2.0\nA;-0.1\nÅland;-99.9\nA;0.0\nZ;2.1";
const expected = "{A=-0.1/0.0/0.0, Z=2.0/2.1/2.1, Åland=-99.9/-99.9/-99.9}\n";

test "both app paths stream the same aggregate from an injected reader" {
    inline for (.{ app, plain }) |pipeline| {
        var stations = try domain.Stations.init(alloc);
        defer stations.deinit(alloc);
        var reader: std.Io.Reader = .fixed(sample);
        try pipeline.read(&stations, &reader);
        var buffer: [512]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try stations.report(alloc, &out);
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}

test "both executables match the expected sorted output and reject malformed rows" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var full: [domain.max_line + 1]u8 = @splat('x');
    @memcpy(full[100..], ";-99.9\n");
    try dir.dir.writeFile(io, .{ .sub_path = "measurements.txt", .data = sample });
    try dir.dir.writeFile(io, .{ .sub_path = "bad.txt", .data = sample ++ "\ninvalid\n" });
    try dir.dir.writeFile(io, .{ .sub_path = "full.txt", .data = &full });
    for ([_][]const u8{ options.executable, options.plain_executable }) |exe| {
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, exe, alloc);
        defer alloc.free(path);
        try check(path, dir.dir, "measurements.txt", expected);
        try check(path, dir.dir, "full.txt", "{" ++ "xxxxxxxxxxxxxxxxxxxx" ++ "xxxxxxxxxxxxxxxxxxxx" ++
            "xxxxxxxxxxxxxxxxxxxx" ++ "xxxxxxxxxxxxxxxxxxxx" ++ "xxxxxxxxxxxxxxxxxxxx" ++ "=-99.9/-99.9/-99.9}\n");
        try check(path, dir.dir, "bad.txt", null);
    }
}

fn check(path: []const u8, dir: std.Io.Dir, input: []const u8, want: ?[]const u8) !void {
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ path, input },
        .cwd = .{ .dir = dir },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (want) |output| {
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings(output, result.stdout);
    } else {
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectEqualStrings("fatal: InvalidMeasurement\n", result.stderr);
    }
}
