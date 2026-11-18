const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn invoke(exe_path: []const u8, dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stdout: []const u8, stderr: []const u8) !void {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, exe_path, allocator);
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

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

const line = "{\"id\":1,\"ts_ms\":2,\"action\":\"read\",\"resource\":\"r\",\"actor\":\"private\"}";
const redacted = "{\"id\":1,\"ts_ms\":2,\"action\":\"read\",\"resource\":\"r\"}\n";

fn repeat(comptime item: []const u8, comptime count: usize) [item.len * count]u8 {
    @setEvalBranchQuota(10000);
    var result: [item.len * count]u8 = undefined;
    for (0..count) |i| @memcpy(result[i * item.len ..][0..item.len], item);
    return result;
}

test "the archive CLI publishes every redacted record including the EOF remainder" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const records = app.batch_size * (app.queue_depth + 1) + 1;
    const input = repeat(line ++ "\n", records);
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = input[0 .. input.len - 1] });
    try invoke(options.executable, temp.dir, &.{ "input", "archive" }, 0, "", "");
    try expectFile(temp.dir, "archive", &repeat(redacted, records));
    try invoke(options.executable, temp.dir, &.{ "input", "archive" }, 2, "", "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "archive", &repeat(redacted, records));
}

test "a malformed record after a full batch leaves no archive" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = &(repeat(line ++ "\n", app.batch_size) ++ "private payload\n".*) });
    try invoke(options.executable, temp.dir, &.{ "input", "archive" }, 2, "", "fatal: InvalidRecord\n");
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "archive", .{}));
}

test "an injected output failure is returned" {
    var input: std.Io.Reader = .fixed(line);
    var short: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, app.archive(io, &input, &writer));
}

const Gate = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    result: std.Io.Writer,
    arrived: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    blocked: std.Io.Event = .unset,
    table: std.Io.VTable = undefined,

    // The test source marks its own thread so the hook ignores the supervisor
    // and consumer. The gate and test waits use the original Io directly.
    threadlocal var source_gate: ?*Gate = null;

    fn observedIo(self: *Gate) std.Io {
        self.table = io.vtable.*;
        self.table.futexWait = futexWait;
        return .{ .userdata = io.userdata, .vtable = &self.table };
    }

    fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (source_gate) |gate| gate.blocked.set(io);
        return io.vtable.futexWait(userdata, ptr, expected, timeout);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Gate = @fieldParentPtr("writer", w);
        if (!self.arrived.isSet()) {
            self.arrived.set(io);
            self.release.wait(io) catch return error.WriteFailed;
        }
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try self.result.writeAll(part);
            total += part.len;
        }
        for (0..splat) |_| {
            try self.result.writeAll(data[data.len - 1]);
            total += data[data.len - 1].len;
        }
        return total;
    }

    fn produce(gate: *Gate, out: anytype) !void {
        defer source_gate = null;
        const count = 7;
        for (0..count) |i| {
            // Once a batch is held in the writer, subsequent pushes cannot
            // contend with its queue reads. One batch fits, the next waits.
            if (i == 2) try gate.arrived.wait(io);
            if (i == 5) source_gate = gate;
            var item: app.Line = .{ .bytes = undefined, .len = line.len };
            @memcpy(item.bytes[0..line.len], line);
            item.bytes[6] = '1' + @as(u8, @intCast(i));
            if (try out.push(item) == .done) return;
        }
    }

    fn run(gate: *Gate) !void {
        var slots: [1]zrx.Batch(app.records.Record, 2) = undefined;
        const program = zrx.program(zrx.fromProducer(app.Line, produce), app.archivePipe(2, &slots));
        try program.run(.{ gate.observedIo(), gate, app.Archive{ .writer = &gate.writer } });
    }
};

fn awaitEvent(event: *std.Io.Event) !void {
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    while (!event.isSet()) {
        event.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => if (deadline.deadline.durationFromNow(io).raw.nanoseconds <= 0)
                return error.TestTimedOut,
            else => return err,
        };
    }
}

test "a stalled writer fills the batch queue, suspends the source and then preserves every record" {
    var output: [512]u8 = undefined;
    var gate: Gate = .{ .result = .fixed(&output) };
    var run = try io.concurrent(Gate.run, .{&gate});
    defer _ = run.cancel(io) catch {};
    defer gate.release.set(io);
    try awaitEvent(&gate.blocked);
    try std.testing.expect(gate.arrived.isSet());
    gate.release.set(io);
    try run.await(io);
    var expected = repeat(redacted, 7);
    for (0..7) |i| expected[i * redacted.len + 6] = '1' + @as(u8, @intCast(i));
    try std.testing.expectEqualStrings(&expected, gate.result.buffered());
}

fn failFlush(_: *std.Io.Writer) std.Io.Writer.Error!void {
    return error.WriteFailed;
}

test "an error flushing the last buffered bytes fails the archive" {
    var input: std.Io.Reader = .fixed(line);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .{ .buffer = &buffer, .vtable = &.{
        .drain = std.Io.Writer.fixedDrain,
        .flush = failFlush,
    } };
    try std.testing.expectError(error.WriteFailed, app.archive(io, &input, &writer));
    try std.testing.expectEqualStrings(redacted, writer.buffered());
}

test "standalone Zig and zrx CLIs agree in sync and queued modes" {
    const count = app.batch_size * (app.queue_depth + 1) + 1;
    const valid = repeat(line ++ "\n", count);
    for ([_][]const u8{ options.executable, options.plain_executable }) |exe_path| {
        for ([_]bool{ false, true }) |sync| {
            var temp = std.testing.tmpDir(.{});
            defer temp.cleanup();
            try temp.dir.writeFile(io, .{ .sub_path = "input", .data = valid[0 .. valid.len - 1] });
            try invoke(exe_path, temp.dir, if (sync) &.{ "--sync", "input", "archive" } else &.{ "input", "archive" }, 0, "", "");
            try expectFile(temp.dir, "archive", &repeat(redacted, count));
            try temp.dir.writeFile(io, .{ .sub_path = "invalid", .data = "invalid\n" });
            try invoke(exe_path, temp.dir, if (sync) &.{ "--sync", "invalid", "missing" } else &.{ "invalid", "missing" }, 2, "", "fatal: InvalidRecord\n");
            try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "missing", .{}));
        }
    }
}
