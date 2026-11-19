//! The production composition with injected I/O, then the real executable.
const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const allocator = std.testing.allocator;
const io = std.testing.io;

const composition = app.composition;
const Summary = app.summaries.Summary;

// --- the composition, with readers and writers supplied by the test ---------

const Run = struct {
    accepted: []const u8,
    diagnostics: []const u8,
    console: []const u8,
    summary: Summary,
};

/// Runs the production program over `input`; the returned slices live in `storage`.
fn process(storage: *[3][512]u8, input: []const u8, rules: app.records.Rules) !Run {
    var reader: std.Io.Reader = .fixed(input);
    var accepted: std.Io.Writer = .fixed(&storage[0]);
    var diagnostics: std.Io.Writer = .fixed(&storage[1]);
    var console: std.Io.Writer = .fixed(&storage[2]);
    var summary: Summary = .{};
    try composition.processing.run(.{
        rules,
        composition.Input{ .reader = &reader },
        composition.Accepted{ .writer = &accepted },
        composition.Diagnostics{ .writer = &diagnostics },
        composition.Console{ .writer = &console },
        &summary,
    });
    return .{
        .accepted = accepted.buffered(),
        .diagnostics = diagnostics.buffered(),
        .console = console.buffered(),
        .summary = summary,
    };
}

test "accepted records, diagnostics and the summary each go to their own writer" {
    var storage: [3][512]u8 = undefined;
    const run = try process(&storage, " ab-1 , Ada  Lovelace , 00042\r\nbad!,Bob,9\nc,Cat,0", .{});
    try std.testing.expectEqualStrings("AB-1,Ada Lovelace,42\nC,Cat,0\n", run.accepted);
    try std.testing.expectEqualStrings("record 2: InvalidIdentifier\n", run.diagnostics);
    try std.testing.expectEqualStrings("summary: accepted=2 rejected=1 amount_cents=42\n", run.console);
    try std.testing.expectEqual(Summary{ .accepted = 2, .rejected = 1, .amount_cents = 42 }, run.summary);
}

test "rules are injected policy" {
    var storage: [3][512]u8 = undefined;
    const run = try process(&storage, "a,Ada,42\nb,Bob,43\nc,Cat,0\n", .{ .max_amount_cents = 42 });
    try std.testing.expectEqualStrings("A,Ada,42\nC,Cat,0\n", run.accepted);
    try std.testing.expectEqualStrings("record 2: InvalidAmount\n", run.diagnostics);
    try std.testing.expectEqualStrings("summary: accepted=2 rejected=1 amount_cents=42\n", run.console);
}

test "empty input still reports a summary" {
    var storage: [3][512]u8 = undefined;
    const run = try process(&storage, "", .{});
    try std.testing.expectEqualStrings("", run.accepted);
    try std.testing.expectEqualStrings("", run.diagnostics);
    try std.testing.expectEqualStrings("summary: accepted=0 rejected=0 amount_cents=0\n", run.console);
}

test "exceeding the record limit is fatal and reports no summary" {
    var storage: [3][512]u8 = undefined;
    var reader: std.Io.Reader = .fixed("a,Ada,1\nb,Bob,2\nc,Cat,3\n");
    var accepted: std.Io.Writer = .fixed(&storage[0]);
    var diagnostics: std.Io.Writer = .fixed(&storage[1]);
    var console: std.Io.Writer = .fixed(&storage[2]);
    var summary: Summary = .{};
    const result = composition.processing.run(.{
        app.records.Rules{ .max_records = 2 },
        composition.Input{ .reader = &reader },
        composition.Accepted{ .writer = &accepted },
        composition.Diagnostics{ .writer = &diagnostics },
        composition.Console{ .writer = &console },
        &summary,
    });
    try std.testing.expectError(error.TooManyRecords, result);
    try std.testing.expectEqualStrings("A,Ada,1\nB,Bob,2\n", accepted.buffered());
    try std.testing.expectEqualStrings("", console.buffered());
    try std.testing.expectEqual(Summary{}, summary);
}

test "a failed record write fails the run before any summary" {
    var storage: [3][512]u8 = undefined;
    var reader: std.Io.Reader = .fixed("a,Ada,1\nb,Bob,2\n");
    var small: [10]u8 = undefined;
    var accepted: std.Io.Writer = .fixed(&small);
    var diagnostics: std.Io.Writer = .fixed(&storage[1]);
    var console: std.Io.Writer = .fixed(&storage[2]);
    var summary: Summary = .{};
    const result = composition.processing.run(.{
        app.records.Rules{},
        composition.Input{ .reader = &reader },
        composition.Accepted{ .writer = &accepted },
        composition.Diagnostics{ .writer = &diagnostics },
        composition.Console{ .writer = &console },
        &summary,
    });
    try std.testing.expectError(error.WriteFailed, result);
    try std.testing.expectEqualStrings("", console.buffered());
}

test "a failed summary write is an error even when every record was accepted" {
    var storage: [3][512]u8 = undefined;
    var reader: std.Io.Reader = .fixed("a,Ada,1\n");
    var accepted: std.Io.Writer = .fixed(&storage[0]);
    var diagnostics: std.Io.Writer = .fixed(&storage[1]);
    var small: [4]u8 = undefined;
    var console: std.Io.Writer = .fixed(&small);
    var summary: Summary = .{};
    const result = composition.processing.run(.{
        app.records.Rules{},
        composition.Input{ .reader = &reader },
        composition.Accepted{ .writer = &accepted },
        composition.Diagnostics{ .writer = &diagnostics },
        composition.Console{ .writer = &console },
        &summary,
    });
    try std.testing.expectError(error.WriteFailed, result);
    // Earlier record effects are not undone.
    try std.testing.expectEqualStrings("A,Ada,1\n", accepted.buffered());
}

// --- the executable ------------------------------------------------------------

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(2_000_000));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn waitAndSignal(child: *std.process.Child, done: *std.Io.Event) std.process.Child.WaitError!std.process.Child.Term {
    defer done.set(io);
    return child.wait(io);
}

/// Runs the executable in `dir` with `dir/input` as stdin and its stdout and
/// stderr redirected to files, so nothing can block on a pipe. The whole wait
/// is bounded; the child is killed and reaped on every failure path.
fn simulate(dir: std.Io.Dir, args: []const []const u8, expected_exit: u8, stdout: []const u8, stderr: []const u8) !void {
    const input = try dir.openFile(io, "input", .{});
    defer input.close(io);
    const out = try dir.createFile(io, "stdout", .{});
    defer out.close(io);
    const err = try dir.createFile(io, "stderr", .{});
    defer err.close(io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, options.executable, allocator);
    defer allocator.free(executable);
    try argv.append(allocator, executable);
    try argv.appendSlice(allocator, args);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
        .stdin = .{ .file = input },
        .stdout = .{ .file = out },
        .stderr = .{ .file = err },
    });
    defer child.kill(io);
    var done: std.Io.Event = .unset;
    var waiter = try std.Io.concurrent(io, waitAndSignal, .{ &child, &done });
    defer _ = waiter.cancel(io) catch {};
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    while (!done.isSet()) {
        done.waitTimeout(io, deadline) catch |failure| switch (failure) {
            error.Timeout => {
                // Event permits spurious wakeups; retain one absolute deadline.
                if (deadline.deadline.durationFromNow(io).raw.nanoseconds <= 0)
                    return error.SimulationTimedOut;
            },
            else => return failure,
        };
    }
    const term = try waiter.await(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = expected_exit }, term);
    try expectFile(dir, "stdout", stdout);
    try expectFile(dir, "stderr", stderr);
}

const file_args = &.{ "--input", "input", "--output", "output" };
const stdin_args = &.{ "--input", "-", "--output", "output" };

test "executable defaults to finite stdin for valid, empty and mixed input" {
    const cases = [_]struct {
        input: []const u8,
        output: []const u8,
        stdout: []const u8,
        stderr: []const u8 = "",
        exit: u8 = 0,
    }{
        .{ .input = " a , Ada , 0007\n", .output = "A,Ada,7\n", .stdout = "summary: accepted=1 rejected=0 amount_cents=7\n" },
        .{ .input = "", .output = "", .stdout = "summary: accepted=0 rejected=0 amount_cents=0\n" },
        .{
            .input = "bad\nb,Bob,3\n",
            .output = "B,Bob,3\n",
            .stdout = "summary: accepted=1 rejected=1 amount_cents=3\n",
            .stderr = "record 1: MalformedFields\n",
            .exit = 1,
        },
    };
    for (cases) |case| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        try temp.dir.writeFile(io, .{ .sub_path = "input", .data = case.input });
        try simulate(temp.dir, &.{ "--output", "output" }, case.exit, case.stdout, case.stderr);
        try expectFile(temp.dir, "output", case.output);
    }
}

test "executable normalizes a file with CRLF and an unterminated last record" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = " ab-1 , Ada  Lovelace , 00042\r\nx_2,Bob,1000000000" });
    try simulate(temp.dir, file_args, 0, "summary: accepted=2 rejected=0 amount_cents=1000000042\n", "");
    try expectFile(temp.dir, "output", "AB-1,Ada Lovelace,42\nX_2,Bob,1000000000\n");
}

test "executable reports every rejection in order and keeps going" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{
        .sub_path = "input",
        .data = "a,Ada,7\n?,Bad,1\nb,Bob,-1\nc,Cat,0\nmissing\nx,Two\tNames,3\n\nz,Zed,4,extra\nq,Q,12x\n",
    });
    try simulate(temp.dir, stdin_args, 1, "summary: accepted=2 rejected=7 amount_cents=7\n", "record 2: InvalidIdentifier\n" ++
        "record 3: InvalidAmount\n" ++
        "record 5: MalformedFields\n" ++
        "record 6: InvalidName\n" ++
        "record 7: MalformedFields\n" ++
        "record 8: MalformedFields\n" ++
        "record 9: InvalidAmount\n");
    try expectFile(temp.dir, "output", "A,Ada,7\nC,Cat,0\n");
}

test "executable rejects malformed-only input rather than failing" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "\nno fields\n,,\n" });
    try simulate(temp.dir, file_args, 1, "summary: accepted=0 rejected=3 amount_cents=0\n", "record 1: MalformedFields\nrecord 2: MalformedFields\nrecord 3: InvalidIdentifier\n");
    try expectFile(temp.dir, "output", "");
}

test "a line over the byte limit is fatal, with no summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var oversized: [258]u8 = @splat('a');
    oversized[257] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = &oversized });
    try simulate(temp.dir, file_args, 2, "", "fatal: StreamTooLong\n");
    try expectFile(temp.dir, "output", "");
}

test "a line of exactly the byte limit is read and validated as a record" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var bounded: [257]u8 = @splat('a');
    bounded[256] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = &bounded });
    try simulate(temp.dir, file_args, 1, "summary: accepted=0 rejected=1 amount_cents=0\n", "record 1: MalformedFields\n");
    try expectFile(temp.dir, "output", "");
}

test "one record over the cap is fatal, with no summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const input = try temp.dir.createFile(io, "input", .{});
    {
        defer input.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = input.writerStreaming(io, &buffer);
        for (0..app.records.max_records + 1) |_| try writer.interface.writeAll("a,Ada,1\n");
        try writer.interface.flush();
    }
    try simulate(temp.dir, file_args, 2, "", "fatal: TooManyRecords\n");
    // A fatal run can leave what it had already written: a prefix of whole records.
    const output = try temp.dir.readFileAlloc(io, "output", allocator, .limited(2_000_000));
    defer allocator.free(output);
    const normalized = "A,Ada,1\n";
    try std.testing.expectEqual(@as(usize, 0), output.len % normalized.len);
    try std.testing.expect(output.len / normalized.len <= app.records.max_records);
    var offset: usize = 0;
    while (offset < output.len) : (offset += normalized.len)
        try std.testing.expectEqualStrings(normalized, output[offset..][0..normalized.len]);
}

test "exactly the record cap succeeds with the complete output" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (0..app.records.max_records) |_| {
        try input.appendSlice(allocator, "a,Ada,01\n");
        try expected.appendSlice(allocator, "A,Ada,1\n");
    }
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = input.items });
    try simulate(temp.dir, file_args, 0, "summary: accepted=10000 rejected=0 amount_cents=10000\n", "");
    try expectFile(temp.dir, "output", expected.items);
}

test "executable never overwrites an existing file, including its own input" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a,Ada,1\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "output", .data = "keep me\n" });
    try simulate(temp.dir, file_args, 2, "", "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "output", "keep me\n");
    try simulate(temp.dir, &.{ "--input", "input", "--output", "./input" }, 2, "", "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "input", "a,Ada,1\n");
}

test "a missing input or output directory is a fatal I/O failure" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a,Ada,1\n" });
    try simulate(temp.dir, &.{ "--input", "missing", "--output", "output" }, 2, "", "fatal: FileNotFound\n");
    // The input is opened before the output is created: nothing is left behind.
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "output", .{}));
    try simulate(temp.dir, &.{ "--input", "input", "--output", "missing/output" }, 2, "", "fatal: FileNotFound\n");
}

test "help and invalid usage create no output" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "" });
    try simulate(temp.dir, &.{"--help"}, 0, app.commands.usage, "");
    try simulate(temp.dir, &.{}, 2, "", "fatal: InvalidArguments\n" ++ app.commands.usage);
    try simulate(temp.dir, &.{ "--input", "input", "--output", "input" }, 2, "", "fatal: InvalidArguments\n" ++ app.commands.usage);
    try simulate(temp.dir, &.{ "--input", "missing", "--output", "output", "--unknown" }, 2, "", "fatal: InvalidArguments\n" ++ app.commands.usage);
    try expectFile(temp.dir, "input", "");
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "output", .{}));
}
