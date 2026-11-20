const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;
const Line = app.records.Line;

const exported = "{{\"id\":{d},\"ts_ms\":2,\"action\":\"read\",\"resource\":\"r\",\"actor\":\"private\"}}\n";
const archived = "{{\"id\":{d},\"ts_ms\":2,\"action\":\"read\",\"resource\":\"r\"}}\n";

/// `count` lines of `format`, numbered from 1 in order.
fn numbered(comptime format: []const u8, count: usize) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (1..count + 1) |id| try text.writer.print(format, .{id});
    return text.toOwnedSlice();
}

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

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

/// Nothing but `kept` is in `dir`: no archive, and no temporary file either.
fn expectOnly(dir: std.Io.Dir, kept: []const []const u8) !void {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        for (kept) |name| {
            if (std.mem.eql(u8, name, entry.name)) break;
        } else return error.UnexpectedFile;
    }
}

test "every record is archived in order, including a last partial batch and an unterminated line" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const count = app.batch_size * (app.queue_depth + 1) + 1;
    const input = try numbered(exported, count);
    defer allocator.free(input);
    const expected = try numbered(archived, count);
    defer allocator.free(expected);
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = input[0 .. input.len - 1] });
    try invoke(temp.dir, &.{ "input", "archive" }, 0, "");
    try expectFile(temp.dir, "archive", expected);
    try expectOnly(temp.dir, &.{ "input", "archive" });
}

test "an existing output path is preserved" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "archive", .data = "kept" });
    const input = try numbered(exported, 1);
    defer allocator.free(input);
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = input });
    try invoke(temp.dir, &.{ "input", "archive" }, 2, "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "archive", "kept");
    try expectOnly(temp.dir, &.{ "input", "archive" });
}

test "a malformed record after a full batch fails the run and publishes nothing" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const valid = try numbered(exported, app.batch_size);
    defer allocator.free(valid);
    const input = try std.mem.concat(allocator, u8, &.{ valid, "private payload\n" });
    defer allocator.free(input);
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = input });
    try invoke(temp.dir, &.{ "input", "archive" }, 2, "fatal: SyntaxError\n");
    try expectOnly(temp.dir, &.{"input"});
}

test "a missing input and a wrong argument count are fatal" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try invoke(temp.dir, &.{ "input", "archive" }, 2, "fatal: FileNotFound\n");
    try invoke(temp.dir, &.{"input"}, 2, "fatal: InvalidArguments\n");
    try invoke(temp.dir, &.{ "input", "archive", "more" }, 2, "fatal: InvalidArguments\n");
    try expectOnly(temp.dir, &.{});
}

/// What a run failed with. `run` returns nothing: a failure goes to a
/// rescue, and a test binds one that hands it back.
const Failure = struct { err: ?anyerror = null };

fn noteFailure(failure: *Failure, err: anyerror) void {
    failure.err = err;
}

/// Runs `runnable` and returns what it failed with.
fn tryRun(runnable: anytype, deps: anytype) anyerror!void {
    var failure: Failure = .{};
    runnable.run(deps ++ .{ &failure, zrx.rescue(noteFailure) });
    if (failure.err) |err| return err;
}

/// Runs the production program on `input` in memory.
fn archive(input: []const u8, writer: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(input);
    try tryRun(app.archiving, .{ io, app.Input{ .reader = &reader }, app.Archive{ .writer = writer } });
}

/// A writer in memory that counts how often it is flushed.
const Counted = struct {
    writer: std.Io.Writer,
    flushes: usize = 0,

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Counted = @fieldParentPtr("writer", w);
        self.flushes += 1;
    }
};

test "the program archives a reader into a writer, which it flushes once" {
    const input = try numbered(exported, app.batch_size + 1);
    defer allocator.free(input);
    const expected = try numbered(archived, app.batch_size + 1);
    defer allocator.free(expected);
    const buffer = try allocator.alloc(u8, expected.len);
    defer allocator.free(buffer);
    var output: Counted = .{ .writer = .{ .buffer = buffer, .vtable = &.{
        .drain = std.Io.Writer.fixedDrain,
        .flush = Counted.flush,
    } } };
    try archive(input, &output.writer);
    try std.testing.expectEqualStrings(expected, output.writer.buffered());
    try std.testing.expectEqual(1, output.flushes);
}

test "an unsafe resource and a failing writer fail the run" {
    var output: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    const unsafe = "{\"id\":1,\"ts_ms\":2,\"action\":\"read\",\"resource\":\"a b\",\"actor\":\"a\"}\n";
    try std.testing.expectError(error.UnsafeResource, archive(unsafe, &writer));
    try std.testing.expectEqualStrings("", writer.buffered());
    const input = try numbered(exported, 1);
    defer allocator.free(input);
    var short: std.Io.Writer = .fixed(output[0..1]);
    try std.testing.expectError(error.WriteFailed, archive(input, &short));
}

/// The most records a source can have handed over while nothing is written:
/// the queued batches, the one being written and the one waiting for a slot.
const held = app.batch_size * (app.queue_depth + 2);

/// An archive whose first write waits to be released, a source that says how
/// far it got, and an `Io` that tells when that source waits.
const Gate = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    result: std.Io.Writer,
    arrived: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    blocked: std.Io.Event = .unset,
    sent: std.atomic.Value(usize) = .init(0),
    table: std.Io.VTable = undefined,

    // The source marks its own thread, so the hook ignores the supervisor and
    // the task behind the queue. The gate and the test wait on the original Io.
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
        var buffer: [128]u8 = undefined;
        for (1..held + 2) |id| {
            // Once the first batch is held in the writer, nothing takes from
            // the queue, so the pushes after it cannot contend with a read.
            if (id == app.batch_size + 1) try gate.arrived.wait(io);
            // This record completes the batch no slot is left for.
            if (id == held) source_gate = gate;
            const line: Line = try .from(std.mem.trimEnd(u8, try std.fmt.bufPrint(&buffer, exported, .{id}), "\n"));
            if (try out.push(line) == .done) return;
            gate.sent.store(id, .release);
        }
    }

    fn run(gate: *Gate) !void {
        const program = zrx.program(zrx.fromProducer(Line, produce), app.archive);
        try tryRun(program, .{ gate.observedIo(), gate, app.Archive{ .writer = &gate.writer } });
    }
};

/// Waits on the event; the deadline only keeps a broken run from hanging.
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

test "a stalled archive fills the queue, suspends the source and then loses no record" {
    const expected = try numbered(archived, held + 1);
    defer allocator.free(expected);
    const output = try allocator.alloc(u8, expected.len);
    defer allocator.free(output);
    var gate: Gate = .{ .result = .fixed(output) };
    var run = try io.concurrent(Gate.run, .{&gate});
    defer _ = run.cancel(io) catch {};
    defer gate.release.set(io);
    try awaitEvent(&gate.blocked);
    // The source waits inside the push of record `held`, with nothing written.
    try std.testing.expectEqual(held - 1, gate.sent.load(.acquire));
    try std.testing.expectEqualStrings("", gate.result.buffered());
    gate.release.set(io);
    try run.await(io);
    try std.testing.expectEqualStrings(expected, gate.result.buffered());
}
