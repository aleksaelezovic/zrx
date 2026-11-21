const std = @import("std");
const app = @import("app");
const zrx = @import("zrx");
const options = @import("options");
const io = std.testing.io;
const allocator = std.testing.allocator;

const document =
    "# people\n" ++
    "<http://ex.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" <http://ex.org/people> .\n" ++
    "<http://ex.org/alice>   <http://xmlns.com/foaf/0.1/knows>\t_:bob. # a friend\r\n" ++
    "\n" ++
    "this is not a statement\n" ++
    "_:bob <http://xmlns.com/foaf/0.1/age> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n" ++
    "<http://ex.org/carol> <http://ex.org/says> <<( _:bob <http://xmlns.com/foaf/0.1/knows> <http://ex.org/alice> )>> <http://ex.org/people> .\n" ++
    "<http://ex.org/alice> <http://xmlns.com/foaf/0.1/name> Alice .\n" ++
    "<x:s> <x:p> <<(<x:a> <x:p> <<(<x:b> <x:p> <<(<x:c> <x:p> <<(<x:d> <x:p> <<(<x:e> <x:p> <x:f>)>>)>>)>>)>>)>> .";

const tidied =
    "<http://ex.org/alice> <http://xmlns.com/foaf/0.1/name> \"Alice\" <http://ex.org/people> .\n" ++
    "<http://ex.org/alice> <http://xmlns.com/foaf/0.1/knows> _:bob .\n" ++
    "_:bob <http://xmlns.com/foaf/0.1/age> \"42\"^^<http://www.w3.org/2001/XMLSchema#integer> .\n" ++
    "<http://ex.org/carol> <http://ex.org/says> <<( _:bob <http://xmlns.com/foaf/0.1/knows> <http://ex.org/alice> )>> <http://ex.org/people> .\n";

const rejections = "line 5: not a statement\nline 8: not a statement\nline 9: nested deeper than 4\n";

/// What a run of the production program wrote.
const Log = struct {
    output: std.Io.Writer,
    diagnostics: std.Io.Writer,
    summary: app.Summary = .{},

    fn init(output: []u8, diagnostics: []u8) Log {
        return .{ .output = .fixed(output), .diagnostics = .fixed(diagnostics) };
    }
};

/// The production program over `text`, written to `log`.
fn check(text: []const u8, log: *Log) !void {
    var reader: std.Io.Reader = .fixed(text);
    try tryRun(app.check, .{
        io,
        &log.summary,
        app.Input{ .reader = &reader },
        app.Output{ .writer = &log.output },
        app.Diagnostics{ .writer = &log.diagnostics },
    });
}

test "statements are written the one way, and the other lines reported by number" {
    var buffers: [2][2048]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    try check(document, &log);
    try std.testing.expectEqualStrings(tidied, log.output.buffered());
    try std.testing.expectEqualStrings(rejections, log.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{ .statements = 4, .in_graphs = 2, .rejected = 3 }, log.summary);
}

/// An IRI of `len` bytes.
inline fn iriOf(comptime len: usize) []const u8 {
    return "<x:" ++ @as([len - 4]u8, @splat('a')) ++ ">";
}

/// A statement with nothing between its terms, and the same written the
/// one way, which is three bytes longer.
inline fn adjacent(comptime object_len: usize) []const u8 {
    return iriOf(200) ++ iriOf(100) ++ iriOf(object_len) ++ ".";
}
inline fn apart(comptime object_len: usize) []const u8 {
    return iriOf(200) ++ " " ++ iriOf(100) ++ " " ++ iriOf(object_len) ++ " .";
}

test "what is written can be read again: a statement longer than a line once tidied is not written" {
    const max_line = app.nquads.max_line;
    // 512 bytes as it stands, 515 written the one way.
    try std.testing.expectEqual(max_line, adjacent(211).len);
    // 509 bytes as it stands, 512 written the one way.
    try std.testing.expectEqual(max_line, apart(208).len);

    var buffers: [2][2048]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    try check(adjacent(211) ++ "\n" ++ adjacent(208) ++ "\n", &log);
    try std.testing.expectEqualStrings(apart(208) ++ "\n", log.output.buffered());
    try std.testing.expectEqualStrings("line 1: longer than 512 bytes once tidied\n", log.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{ .statements = 1, .rejected = 1 }, log.summary);

    // The output is all statements that fit, written the one way already.
    var again_buffers: [2][2048]u8 = undefined;
    var again: Log = .init(&again_buffers[0], &again_buffers[1]);
    try check(log.output.buffered(), &again);
    try std.testing.expectEqualStrings(log.output.buffered(), again.output.buffered());
    try std.testing.expectEqualStrings("", again.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{ .statements = 1 }, again.summary);
}

/// A statement with a triple term written without spaces, and the same
/// written the one way, which is two bytes longer.
inline fn compact(comptime object_len: usize) []const u8 {
    return iriOf(100) ++ " <x:p> <<(" ++ iriOf(200) ++ " <x:p> " ++ iriOf(object_len) ++ ")>> .";
}
inline fn spaced(comptime object_len: usize) []const u8 {
    return iriOf(100) ++ " <x:p> <<( " ++ iriOf(200) ++ " <x:p> " ++ iriOf(object_len) ++ " )>> .";
}

test "what is written can be read again, with a triple term that is written longer" {
    const max_line = app.nquads.max_line;
    // 512 bytes as it stands, 514 written the one way.
    try std.testing.expectEqual(max_line, compact(190).len);
    // 510 bytes as it stands, 512 written the one way.
    try std.testing.expectEqual(max_line, spaced(188).len);

    var buffers: [2][2048]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    try check(compact(190) ++ "\n" ++ compact(188) ++ "\n", &log);
    try std.testing.expectEqualStrings(spaced(188) ++ "\n", log.output.buffered());
    try std.testing.expectEqualStrings("line 1: longer than 512 bytes once tidied\n", log.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{ .statements = 1, .rejected = 1 }, log.summary);

    // The output is all statements that fit, written the one way already.
    var again_buffers: [2][2048]u8 = undefined;
    var again: Log = .init(&again_buffers[0], &again_buffers[1]);
    try check(log.output.buffered(), &again);
    try std.testing.expectEqualStrings(log.output.buffered(), again.output.buffered());
    try std.testing.expectEqualStrings("", again.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{ .statements = 1 }, again.summary);
}

test "the summary that cannot be written fails by itself, after the statements were" {
    var none: [0]u8 = .{};
    var console: std.Io.Writer = .fixed(&none);
    var exit: app.Exit = .{};
    try std.testing.expectError(error.WriteFailed, tryRun(
        zrx.program(zrx.fromValue(app.Summary{ .statements = 1 }), app.report),
        .{ &exit, app.Console{ .writer = &console } },
    ));
}

test "a file of comments and nothing else holds no statement and no fault" {
    var buffers: [2][64]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    try check("# nothing\n\n   \n\t# here\r\n", &log);
    try std.testing.expectEqualStrings("", log.output.buffered());
    try std.testing.expectEqualStrings("", log.diagnostics.buffered());
    try std.testing.expectEqual(app.Summary{}, log.summary);
}

test "a line longer than a line may be fails the run" {
    var buffers: [2][64]u8 = undefined;
    var log: Log = .init(&buffers[0], &buffers[1]);
    const long: [app.nquads.max_line + 1]u8 = @splat('x');
    try std.testing.expectError(error.StreamTooLong, check(&long, &log));
}

test "the report is the summary as JSON, and a rejected line is exit status 1" {
    inline for (.{
        .{ app.Summary{ .statements = 3, .in_graphs = 1 }, 0, "{\"statements\":3,\"in_graphs\":1,\"rejected\":0}\n" },
        .{ app.Summary{ .statements = 3, .rejected = 2 }, 1, "{\"statements\":3,\"in_graphs\":0,\"rejected\":2}\n" },
    }) |case| {
        var buffer: [128]u8 = undefined;
        var console: std.Io.Writer = .fixed(&buffer);
        var exit: app.Exit = .{};
        try tryRun(zrx.program(zrx.fromValue(case[0]), app.report), .{ &exit, app.Console{ .writer = &console } });
        try std.testing.expectEqual(case[1], exit.code);
        try std.testing.expectEqualStrings(case[2], console.buffered());
    }
}

// --- the executable ----------------------------------------------------------------

const Outcome = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(outcome: Outcome) void {
        allocator.free(outcome.stdout);
        allocator.free(outcome.stderr);
    }
};

fn invoke(dir: std.Io.Dir, args: []const []const u8) !Outcome {
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
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited);
    return .{ .exit = result.term.exited, .stdout = result.stdout, .stderr = result.stderr };
}

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "the executable tidies a file, reports what is no statement and says what it held" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "in.nq", .data = document });

    const first = try invoke(temp.dir, &.{ "in.nq", "out.nq" });
    defer first.deinit();
    try std.testing.expectEqual(1, first.exit);
    try std.testing.expectEqualStrings(rejections, first.stderr);
    try std.testing.expectEqualStrings("{\"statements\":4,\"in_graphs\":2,\"rejected\":3}\n", first.stdout);
    try expectFile(temp.dir, "out.nq", tidied);

    // What it wrote is all statements, already written the one way.
    const second = try invoke(temp.dir, &.{ "out.nq", "again.nq" });
    defer second.deinit();
    try std.testing.expectEqual(0, second.exit);
    try std.testing.expectEqualStrings("", second.stderr);
    try std.testing.expectEqualStrings("{\"statements\":4,\"in_graphs\":2,\"rejected\":0}\n", second.stdout);
    try expectFile(temp.dir, "again.nq", tidied);
}

test "the executable replaces no output and reads no missing input" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "in.nq", .data = "<x:s> <x:p> <x:o> .\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "out.nq", .data = "kept\n" });
    const taken = try invoke(temp.dir, &.{ "in.nq", "out.nq" });
    defer taken.deinit();
    try std.testing.expectEqual(2, taken.exit);
    try std.testing.expectEqualStrings("", taken.stdout);
    try std.testing.expectEqualStrings("fatal: PathAlreadyExists\n", taken.stderr);
    try expectFile(temp.dir, "out.nq", "kept\n");

    const missing = try invoke(temp.dir, &.{ "none.nq", "other.nq" });
    defer missing.deinit();
    try std.testing.expectEqual(2, missing.exit);
    try std.testing.expectEqualStrings("fatal: FileNotFound\n", missing.stderr);
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "other.nq", .{}));
}

test "the executable rejects any other number of arguments" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const outcome = try invoke(temp.dir, &.{"in.nq"});
    defer outcome.deinit();
    try std.testing.expectEqual(2, outcome.exit);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectEqualStrings("fatal: InvalidArguments\n", outcome.stderr);
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
