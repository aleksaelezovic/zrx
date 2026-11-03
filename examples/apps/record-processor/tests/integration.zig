const std = @import("std");
const builtin = @import("builtin");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const allocator = std.testing.allocator;
const io = std.testing.io;
const run = zrx.run;
const pipe = zrx.pipe;
const fromValue = zrx.fromValue;
const forEach = zrx.forEach;
const deriveResource = zrx.deriveResource;
const byteWriter = zrx.writer;

// Borrowed, already-initialized byte owner fixture. No acquisition/release is
// requested by run; fixed/failing standard interfaces need no OS handle.
fn borrowedReader(interface: std.Io.Reader) zrx.Reader {
    return .{ .input = .stdin, .file_reader = .{ .io = io, .file = .stdin(), .interface = interface } };
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(2_000_000));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "execute propagates cold allocation failure to its caller" {
    const args: std.process.Args = if (builtin.os.tag == .windows)
        .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("record-processor --help") }
    else
        .{ .vector = &.{ "record-processor", "--help" } };
    var failing: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, app.execute(failing.allocator(), io, args));
}

fn checkIdleInput(input: app.resources.Input, output: app.resources.AcceptedOutput, _: u8) !void {
    try std.testing.expect(input.reader.input == .stdin);
    try std.testing.expect(output.writer == null);
}

test "help and invalid commands prepare borrowed stdin without creating output" {
    for ([_]app.commands.Command{ .help, .invalid }) |command| {
        try run(.{
            allocator,
            io,
            command,
            app.resources.input(),
            app.resources.acceptedOutput(),
        }, .{pipe(fromValue(@as(u8, 0)), .{forEach(checkIdleInput)})});
    }
}

test "single command pipeline never traverses process input for help or invalid usage" {
    for ([_]app.commands.Command{ .help, .invalid }) |command| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const stdout = try std.fs.path.join(allocator, &.{ root, "stdout" });
        defer allocator.free(stdout);
        const stderr = try std.fs.path.join(allocator, &.{ root, "stderr" });
        defer allocator.free(stderr);
        // This borrowed input would fail immediately if the process branch
        // traversed it. No process endpoint is involved.
        var input = borrowedReader(.failing);
        const result = run(.{
            allocator,
            io,
            command,
            app.resources.Input{ .reader = &input },
            app.records.Rules{},
            app.resources.AcceptedOutput{ .writer = null },
            deriveResource(app.resources.DiagnosticOutput, byteWriter(.{ .file = .{ .path = stderr, .options = .{ .exclusive = true } } })),
            deriveResource(app.resources.ConsoleOutput, byteWriter(.{ .file = .{ .path = stdout, .options = .{ .exclusive = true } } })),
        }, .{app.composition.commandFlow});
        if (command == .help) {
            try result;
        } else {
            try std.testing.expectError(error.InvalidArguments, result);
        }
        try expectFile(temp.dir, "stdout", if (command == .help) app.commands.usage else "");
        try expectFile(temp.dir, "stderr", if (command == .invalid) "fatal: InvalidArguments\n" ++ app.commands.usage else "");
    }
}

test "production pipeline reports and summarizes with injected rules and resources" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const output = try std.fs.path.join(allocator, &.{ root, "output" });
    defer allocator.free(output);
    const diagnostics = try std.fs.path.join(allocator, &.{ root, "diagnostics" });
    defer allocator.free(diagnostics);
    const summary = try std.fs.path.join(allocator, &.{ root, "summary" });
    defer allocator.free(summary);
    var input = borrowedReader(.fixed("a,Ada,42\nb,Bob,43\nc,Cat,0\n"));
    try std.testing.expectError(error.RejectedRecords, run(.{
        allocator,
        io,
        app.resources.Input{ .reader = &input },
        app.records.Rules{ .max_amount_cents = 42 },
        app.commands.Command{ .process = .{ .input = "unused", .output = output } },
        app.resources.acceptedOutput(),
        deriveResource(app.resources.DiagnosticOutput, byteWriter(.{ .file = .{ .path = diagnostics, .options = .{ .exclusive = true } } })),
        deriveResource(app.resources.ConsoleOutput, byteWriter(.{ .file = .{ .path = summary, .options = .{ .exclusive = true } } })),
    }, .{app.composition.commandFlow}));
    try expectFile(temp.dir, "output", "A,Ada,42\nC,Cat,0\n");
    try expectFile(temp.dir, "diagnostics", "record 2: InvalidAmount\n");
    try expectFile(temp.dir, "summary", "summary: accepted=2 rejected=1 amount_cents=42\n");
}

// A standard writer fixture, injected through the same ConsoleOutput role as
// stdout. It observes the real production terminal and then fails its write.
const SummaryProbe = struct {
    writer: zrx.Writer = .{ .output = .stdout },
    dir: ?std.Io.Dir = null,
    calls: usize = 0,
    failure: ?anyerror = null,

    fn init(self: *SummaryProbe) void {
        self.writer.writer = .{
            .io = io,
            .file = .stdout(),
            .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const file_writer: *std.Io.File.Writer = @fieldParentPtr("interface", writer);
        const output: *zrx.Writer = @fieldParentPtr("writer", file_writer);
        const self: *SummaryProbe = @fieldParentPtr("writer", output);
        self.calls += 1;
        if (self.dir) |dir| self.inspect(dir, data, splat) catch |err| {
            self.failure = err;
        };
        return error.WriteFailed;
    }

    fn inspect(_: *SummaryProbe, dir: std.Io.Dir, data: []const []const u8, splat: usize) !void {
        // Assert ordering at the actual summary write, not after run returns.
        try expectFile(dir, "output", "A,Ada,1\n");
        try expectFile(dir, "diagnostics", "record 2: MalformedFields\n");
        try std.testing.expectEqual(@as(usize, 1), splat);
        try std.testing.expectEqual(@as(usize, 1), data.len);
        try std.testing.expectEqualStrings("summary: accepted=1 rejected=1 amount_cents=1", data[0]);
    }
};

test "both reporting lanes fail unhandled without publishing a summary" {
    inline for (.{ "a,Ada,1", "malformed" }) |input| {
        // Borrowed failing standard writers exercise production reporting, not
        // invented transient domain failures. No real process endpoint is used.
        var accepted: zrx.Writer = .{ .output = .stdout };
        accepted.writer = .{ .io = io, .file = .stdout(), .interface = .failing };
        var diagnostics: zrx.Writer = .{ .output = .stderr };
        diagnostics.writer = .{ .io = io, .file = .stderr(), .interface = .failing };
        var source = borrowedReader(.fixed(input));
        var console: SummaryProbe = .{};
        console.init();
        try std.testing.expectError(error.WriteFailed, run(.{
            allocator,
            io,
            app.resources.Input{ .reader = &source },
            app.records.Rules{},
            app.commands.Command{ .process = .{ .input = "unused", .output = "unused" } },
            app.resources.AcceptedOutput{ .writer = &accepted },
            app.resources.DiagnosticOutput{ .writer = &diagnostics },
            app.resources.ConsoleOutput{ .writer = &console.writer },
        }, .{app.composition.commandFlow}));
        try std.testing.expectEqual(@as(usize, 0), console.calls);
    }
}

test "summary follows flushed record effects and terminal failure fails run" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const output = try std.fs.path.join(allocator, &.{ root, "output" });
    defer allocator.free(output);
    const diagnostics = try std.fs.path.join(allocator, &.{ root, "diagnostics" });
    defer allocator.free(diagnostics);
    var input = borrowedReader(.fixed("a,Ada,1\nmalformed\n"));
    var console: SummaryProbe = .{ .dir = temp.dir };
    console.init();
    try std.testing.expectError(error.WriteFailed, run(.{
        allocator,
        io,
        app.resources.Input{ .reader = &input },
        app.records.Rules{},
        app.commands.Command{ .process = .{ .input = "unused", .output = output } },
        app.resources.acceptedOutput(),
        deriveResource(app.resources.DiagnosticOutput, byteWriter(.{ .file = .{ .path = diagnostics, .options = .{ .exclusive = true } } })),
        app.resources.ConsoleOutput{ .writer = &console.writer },
    }, .{app.composition.commandFlow}));
    try std.testing.expectEqual(@as(usize, 1), console.calls);
    if (console.failure) |err| return err;
    // Summary I/O failure wins over RejectedRecords. Earlier record effects
    // are intentionally not undone.
    try expectFile(temp.dir, "output", "A,Ada,1\n");
    try expectFile(temp.dir, "diagnostics", "record 2: MalformedFields\n");
}

fn waitAndSignal(child: *std.process.Child, done: *std.Io.Event) std.process.Child.WaitError!std.process.Child.Term {
    defer done.set(io);
    return child.wait(io);
}

// Redirect to owned regular files: stdin is finite, output cannot deadlock a
// pipe. Bound the entire wait, not just reads. Cancellation joins the waiter
// before kill/reap touches Child; cleanup runs on every assertion/failure.
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

test "executable defaults to finite stdin for valid empty and mixed input" {
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

test "executable normalizes a file and emits exact successful summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = " ab-1 , Ada  Lovelace , 00042\r\nx_2,Bob,1000000000" });
    try simulate(temp.dir, file_args, 0, "summary: accepted=2 rejected=0 amount_cents=1000000042\n", "");
    try expectFile(temp.dir, "output", "AB-1,Ada Lovelace,42\nX_2,Bob,1000000000\n");
}

test "executable routes mixed-invalid finite stdin and retains later rejections" {
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

test "executable empty input creates empty output and zero summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "" });
    try simulate(temp.dir, file_args, 0, "summary: accepted=0 rejected=0 amount_cents=0\n", "");
    try expectFile(temp.dir, "output", "");
}

test "executable malformed-only records are rejected rather than fatal" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "\nno fields\n,,\n" });
    try simulate(temp.dir, file_args, 1, "summary: accepted=0 rejected=3 amount_cents=0\n", "record 1: MalformedFields\nrecord 2: MalformedFields\nrecord 3: InvalidIdentifier\n");
    try expectFile(temp.dir, "output", "");
}

test "executable byte limit is fatal control flow with no successful summary" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var oversized: [258]u8 = @splat('a');
    oversized[257] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = &oversized });
    try simulate(temp.dir, file_args, 2, "", "fatal: FrameTooLong\n");
    try expectFile(temp.dir, "output", "");
}

test "exact line bound is framed normally and validated as a record" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var bounded: [257]u8 = @splat('a');
    bounded[256] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = &bounded });
    try simulate(temp.dir, file_args, 1, "summary: accepted=0 rejected=1 amount_cents=0\n", "record 1: MalformedFields\n");
    try expectFile(temp.dir, "output", "");
}

test "record cap fails without reporting a false successful summary" {
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
    try simulate(temp.dir, file_args, 2, "", "fatal: TooManyItems\n");
    // Fatal runs can leave partial effects. Assert the guaranteed normalized
    // prefix, not a scheduler-dependent number of previously flushed records.
    const output = try temp.dir.readFileAlloc(io, "output", allocator, .limited(2_000_000));
    defer allocator.free(output);
    const normalized = "A,Ada,1\n";
    try std.testing.expectEqual(@as(usize, 0), output.len % normalized.len);
    try std.testing.expect(output.len / normalized.len <= app.records.max_records);
    var offset: usize = 0;
    while (offset < output.len) : (offset += normalized.len)
        try std.testing.expectEqualStrings(normalized, output[offset..][0..normalized.len]);
}

test "exact record cap succeeds with the complete normalized output" {
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

test "executable refuses overwrites including output aliases of input" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a,Ada,1\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "output", .data = "keep me\n" });
    try simulate(temp.dir, file_args, 2, "", "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "output", "keep me\n");
    try simulate(temp.dir, &.{ "--input", "input", "--output", "./input" }, 2, "", "fatal: PathAlreadyExists\n");
    try expectFile(temp.dir, "input", "a,Ada,1\n");
}

test "executable missing input and output directory are fatal I/O failures" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a,Ada,1\n" });
    try simulate(temp.dir, &.{ "--input", "missing", "--output", "output" }, 2, "", "fatal: FileNotFound\n");
    try simulate(temp.dir, &.{ "--input", "input", "--output", "missing/output" }, 2, "", "fatal: FileNotFound\n");
}

test "executable help and invalid usage do not create output" {
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
