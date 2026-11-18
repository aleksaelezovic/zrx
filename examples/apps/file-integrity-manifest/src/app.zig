const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const map = zrx.map;
const concurrent = zrx.concurrent;
const forEach = zrx.forEach;

const workers = 4;
pub const chunk_bytes = 32 * 1024;
pub const Files = struct { dir: Io.Dir };
const Sink = struct { writer: *Io.Writer, failures: *usize };

const Job = struct { index: usize, path: []const u8 };
const Digest = struct { bytes: u64, hash: [Sha256.digest_length]u8 };
const Result = struct { job: Job, digest: anyerror!Digest };

fn hashFile(io: Io, dir: Io.Dir, path: []const u8) !Digest {
    // Avoid opening special files on a stable input tree, and verify the opened
    // handle too. Callers should not change or replace inputs during the scan.
    if ((try dir.statFile(io, path, .{})).kind != .file) return error.NotRegularFile;
    const file = try dir.openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;

    var hash = Sha256.init(.{});
    var chunk: [chunk_bytes]u8 = undefined;
    var bytes: u64 = 0;
    while (bytes < before.size) {
        const limit: usize = @intCast(@min(before.size - bytes, chunk.len));
        const n = file.readStreaming(io, &.{chunk[0..limit]}) catch |err| switch (err) {
            error.EndOfStream => return error.FileChanged,
            else => return err,
        };
        hash.update(chunk[0..n]);
        bytes += n;
    }
    // Some pseudo-files report zero size while still producing data. Detect
    // that case and extensions of ordinary files before accepting the hash.
    while (true) {
        const n = file.readStreaming(io, &.{chunk[0..1]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n != 0) return error.FileChanged;
    }
    const after = try file.stat(io);
    if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds)
        return error.FileChanged;
    return .{ .bytes = bytes, .hash = hash.finalResult() };
}

fn hashJob(io: Io, files: Files, job: Job) Io.Cancelable!Result {
    const digest = hashFile(io, files.dir, job.path) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return .{ .job = job, .digest = err };
    };
    return .{ .job = job, .digest = digest };
}

fn writeResult(sink: Sink, result: Result) !void {
    const j = result.job;
    if (result.digest) |digest| {
        const hex = std.fmt.bytesToHex(digest.hash, .lower);
        try std.json.Stringify.value(.{
            .index = j.index,
            .path = j.path,
            .bytes = digest.bytes,
            .sha256 = hex[0..],
        }, .{}, sink.writer);
    } else |err| {
        sink.failures.* += 1;
        try std.json.Stringify.value(.{ .index = j.index, .path = j.path, .@"error" = @errorName(err) }, .{}, sink.writer);
    }
    try sink.writer.writeByte('\n');
}

const Paths = struct { items: []const []const u8 };

fn jobs(paths: Paths, out: anytype) !void {
    for (paths.items, 1..) |path, index| {
        if (try out.push(Job{ .index = index, .path = path }) == .done) return;
    }
}

pub fn generate(io: Io, files: Files, paths: []const []const u8, output: *Io.Writer) !usize {
    var failures: usize = 0;
    const manifest = zrx.program(zrx.fromProducer(Job, jobs), .{
        concurrent(workers, .{
            map(hashJob),
        }),
        forEach(writeResult),
    });
    try manifest.run(.{ io, files, Paths{ .items = paths }, Sink{ .writer = output, .failures = &failures } });
    try output.flush();
    return failures;
}

const usage = "usage: file-integrity-manifest OUTPUT FILE...\n";

pub fn execute(io: Io, args: []const []const u8) !u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        var buffer: [128]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(io, &buffer);
        try writer.interface.writeAll(usage);
        try writer.interface.flush();
        return 0;
    }
    if (args.len < 2) return error.InvalidArguments;
    for (args[1..]) |path| {
        if (path.len == 0 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    }
    const dir = Io.Dir.cwd();
    var file = try dir.createFileAtomic(io, args[0], .{});
    defer file.deinit(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.file.writerStreaming(io, &buffer);
    const failures = try generate(io, .{ .dir = dir }, args[1..], &writer.interface);
    try file.link(io);
    return if (failures == 0) 0 else 1;
}

test "hashes a file across several read buffers" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var data: [3 * (chunk_bytes + 1)]u8 = undefined;
    for (0..chunk_bytes + 1) |i| @memcpy(data[i * 3 ..][0..3], "abc");
    try temp.dir.writeFile(io, .{ .sub_path = "data", .data = &data });
    const digest = try hashFile(io, temp.dir, "data");
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&data, &expected, .{});
    try std.testing.expectEqual(@as(u64, data.len), digest.bytes);
    try std.testing.expectEqual(expected, digest.hash);
}
