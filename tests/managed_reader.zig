const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromService = zrx.fromService;
const flatMap = zrx.flatMap;
const forEach = zrx.forEach;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn lines(reader: *zrx.Reader) @TypeOf(zrx.readerLines(3, @as(*zrx.Reader, undefined))) {
    return zrx.readerLines(3, reader);
}

const Captured = struct {
    items: [3]zrx.Line(3) = undefined,
    len: usize = 0,
};
fn capture(output: *Captured, value: zrx.Line(3)) void {
    output.items[output.len] = value;
    output.len += 1;
}

fn readAllocation(gpa: std.mem.Allocator, path: []const u8) !void {
    var output: Captured = .{};
    try run(.{ gpa, io, zrx.reader(.{ .file = path }), &output }, .{
        pipe(fromService(*zrx.Reader), .{ flatMap(lines), forEach(capture) }),
    });
    try std.testing.expectEqual(@as(usize, 3), output.len);
    for ([_][]const u8{ "a\r", "", "xyz" }, 0..) |expected, index| {
        const value = output.items[index];
        try std.testing.expectEqualStrings(expected, value.bytes[0..value.len]);
    }
}

// Keep the real Threaded userdata for all operations. Only reader-related
// close/read hooks are overridden; counters remain safe in graph-worker turns.
const TrackedIo = struct {
    backend: std.Io.Threaded,
    vtable: std.Io.VTable = undefined,
    closes: std.atomic.Value(usize) = .init(0),
    active: std.atomic.Value(usize) = .init(0),
    early_close: std.atomic.Value(bool) = .init(false),
    read_failure: ?std.Io.File.ReadStreamingError = null,
    protect_stdin: bool = false,

    fn asIo(self: *TrackedIo) std.Io {
        const original = self.backend.io();
        self.vtable = original.vtable.*;
        self.vtable.fileClose = close;
        self.vtable.operate = operate;
        return .{ .userdata = original.userdata, .vtable = &self.vtable };
    }

    fn owner(userdata: ?*anyopaque) *TrackedIo {
        const backend: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        return @fieldParentPtr("backend", backend);
    }

    fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
        const self = owner(userdata);
        _ = self.closes.fetchAdd(files.len, .monotonic);
        if (self.active.load(.acquire) != 0) self.early_close.store(true, .release);
        for (files) |file| {
            // Detect a bad close without damaging the test process's stdin.
            if (self.protect_stdin and file.handle == std.Io.File.stdin().handle) continue;
            self.backend.io().vtable.fileClose(userdata, &.{file});
        }
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self = owner(userdata);
        if (operation == .file_read_streaming) {
            if (self.read_failure) |err| {
                if (err == error.Canceled) return error.Canceled;
                return .{ .file_read_streaming = @as(std.Io.Operation.FileReadStreaming.Error, @errorCast(err)) };
            }
        }
        return self.backend.io().vtable.operate(userdata, operation);
    }
};

const Users = struct {
    tracking: *TrackedIo,
    count: std.atomic.Value(usize) = .init(0),
};
fn useReader(users: *Users, reader: *zrx.Reader, _: zrx.Line(3)) !void {
    _ = users.tracking.active.fetchAdd(1, .acq_rel);
    defer _ = users.tracking.active.fetchSub(1, .acq_rel);
    try std.testing.expectEqual(@as(usize, 0), users.tracking.closes.load(.acquire));
    _ = try reader.file.stat(reader.io);
    _ = users.count.fetchAdd(1, .monotonic);
}
fn forbidden(_: anyerror) zrx.Line(3) {
    @panic("reader control failure reached operation recovery");
}

test "managed reader is cold, opens afresh per run and cleans allocation failures" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(path);
    const recipe = zrx.reader(.{ .file = path });
    // Describing a missing file is cold. Only run can observe its absence.
    try run(.{ allocator, io, recipe }, .{
        pipe(zrx.fromValue(@as(u8, 0)), .{zrx.discard()}),
    });
    try std.testing.expectError(error.FileNotFound, run(.{ allocator, io, recipe }, .{
        pipe(fromService(*zrx.Reader), .{zrx.discard()}),
    }));
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\r\n\nxyz" });
    try readAllocation(allocator, path);
    try readAllocation(allocator, path);
    try std.testing.checkAllAllocationFailures(allocator, readAllocation, .{path});
}

test "managed reader closes its file once after shared users stop" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\nb\nc\n" });
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(path);
    var tracking: TrackedIo = .{ .backend = .init(allocator, .{}) };
    defer tracking.backend.deinit();
    const tracked = tracking.asIo();
    var users: Users = .{ .tracking = &tracking };
    const source = pipe(fromService(*zrx.Reader), .{flatMap(lines)});
    try run(.{ allocator, tracked, zrx.reader(.{ .file = path }), &users }, .{
        pipe(&source, .{forEach(useReader)}),
        pipe(&source, .{forEach(useReader)}),
    });
    try std.testing.expectEqual(@as(usize, 6), users.count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), tracking.closes.load(.acquire));
    try std.testing.expect(!tracking.early_close.load(.acquire));
}

test "managed reader releases on bounds, read failure and cancellation without recovery" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "long\n" });
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(path);
    for ([_]?std.Io.File.ReadStreamingError{ null, error.InputOutput, error.Canceled }) |failure| {
        var tracking: TrackedIo = .{ .backend = .init(allocator, .{}), .read_failure = failure };
        defer tracking.backend.deinit();
        const result = run(.{ allocator, tracking.asIo(), zrx.reader(.{ .file = path }) }, .{
            pipe(fromService(*zrx.Reader), .{ flatMap(lines), zrx.recover(forbidden), zrx.discard() }),
        });
        if (failure) |err| {
            try std.testing.expectError(err, result);
        } else {
            try std.testing.expectError(error.LineTooLong, result);
        }
        try std.testing.expectEqual(@as(usize, 1), tracking.closes.load(.acquire));
    }
}

test "stdin ownership stays borrowed and take zero never reads" {
    var tracking: TrackedIo = .{
        .backend = .init(allocator, .{}),
        .read_failure = error.InputOutput,
        .protect_stdin = true,
    };
    defer tracking.backend.deinit();
    try run(.{ allocator, tracking.asIo(), zrx.reader(.stdin) }, .{
        pipe(fromService(*zrx.Reader), .{ flatMap(lines), zrx.take(0), zrx.discard() }),
    });
    try std.testing.expectEqual(@as(usize, 0), tracking.closes.load(.acquire));
}

const Input = struct { reader: *zrx.Reader };
const Output = struct { writer: *zrx.Writer };
const Paths = struct { input: []const u8, output: []const u8 };
const Settings = struct { input: []const u8, output: []const u8 };
const ConfigurationTrace = struct {
    tracking: *TrackedIo,
    expected_closes: usize = 0,
    alive: bool = false,
    acquired: usize = 0,
    released: usize = 0,
    reader_calls: usize = 0,
    writer_calls: usize = 0,
    released_after_owners: bool = true,
};

fn acquireSettings(gpa: std.mem.Allocator, trace: *ConfigurationTrace, paths: Paths, _: void) !Settings {
    const input = try gpa.dupe(u8, paths.input);
    errdefer gpa.free(input);
    const output = try gpa.dupe(u8, paths.output);
    trace.alive = true;
    trace.acquired += 1;
    return .{ .input = input, .output = output };
}

fn releaseSettings(gpa: std.mem.Allocator, trace: *ConfigurationTrace, settings: Settings) void {
    trace.released_after_owners = trace.released_after_owners and
        trace.tracking.closes.load(.acquire) == trace.expected_closes;
    trace.alive = false;
    trace.released += 1;
    gpa.free(settings.output);
    gpa.free(settings.input);
}

fn readerConfig(trace: *ConfigurationTrace, settings: Settings) zrx.Reader.Config {
    std.debug.assert(trace.alive);
    trace.reader_calls += 1;
    return .{ .file = settings.input };
}

fn writerConfig(trace: *ConfigurationTrace, settings: Settings) error{Unused}!zrx.Writer.Config {
    std.debug.assert(trace.alive);
    trace.writer_calls += 1;
    return .{ .file = .{ .path = settings.output, .options = .{ .exclusive = true } } };
}

fn inputChunks(input: Input) @TypeOf(zrx.readChunks(4, @as(*zrx.Reader, undefined))) {
    return zrx.readChunks(4, input.reader);
}

fn copyChunk(output: Output, value: zrx.Chunk(u8, 4)) !void {
    try output.writer.write(value.slice());
    try output.writer.flush();
}

test "configuration providers are cold, shared per run and retain parent resources through release" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const content = "a\r\n\nxyz";
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = content });
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const input_path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(input_path);
    var tracking: TrackedIo = .{ .backend = .init(allocator, .{}) };
    defer tracking.backend.deinit();
    var trace: ConfigurationTrace = .{ .tracking = &tracking };
    const input = zrx.deriveResource(Input, zrx.reader(readerConfig));
    const output = zrx.deriveResource(Output, zrx.writer(writerConfig));
    try std.testing.expectEqual(@as(usize, 0), trace.reader_calls);
    try std.testing.expectEqual(@as(usize, 0), trace.writer_calls);
    const source = pipe(fromService(Input), .{flatMap(inputChunks)});
    for ([_][]const u8{ "first", "second" }, 1..) |name, iteration| {
        const output_path = try std.fs.path.join(allocator, &.{ root, name });
        defer allocator.free(output_path);
        trace.expected_closes = iteration * 2;
        // Deliberately reverse dependency order in the tuple. Both providers
        // borrow paths from the same managed settings; two terminal users share
        // one input traversal and acquisition, not one provider call per chunk.
        try run(.{
            allocator,
            tracking.asIo(),
            output,
            input,
            zrx.resource({}, acquireSettings, releaseSettings),
            Paths{ .input = input_path, .output = output_path },
            &trace,
        }, .{
            pipe(&source, .{forEach(copyChunk)}),
            pipe(&source, .{zrx.discard()}),
        });
        try std.testing.expect(!trace.alive);
        try std.testing.expect(trace.released_after_owners);
        try std.testing.expectEqual(iteration, trace.acquired);
        try std.testing.expectEqual(iteration, trace.released);
        try std.testing.expectEqual(iteration, trace.reader_calls);
        try std.testing.expectEqual(iteration, trace.writer_calls);
        const actual = try temp.dir.readFileAlloc(io, name, allocator, .limited(128));
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(content, actual);
    }
}

fn failedReader(calls: *usize) error{ConfigurationFailed}!zrx.Reader.Config {
    calls.* += 1;
    return error.ConfigurationFailed;
}
fn canceledWriter(calls: *usize) error{Canceled}!zrx.Writer.Config {
    calls.* += 1;
    return error.Canceled;
}
fn failedSettings(_: Settings) error{ConfigurationFailed}!zrx.Reader.Config {
    return error.ConfigurationFailed;
}
fn forbiddenReaderRecovery(_: anyerror) *zrx.Reader {
    @panic("configuration failure reached operation recovery");
}
fn forbiddenWriterRecovery(_: anyerror) *zrx.Writer {
    @panic("configuration cancellation reached operation recovery");
}

test "unused configuration providers stay cold and provider errors remain acquisition control" {
    // Missing provider services are irrelevant while the recipes are unreachable.
    try run(.{ allocator, io, zrx.reader(readerConfig), zrx.writer(writerConfig) }, .{
        pipe(zrx.fromValue(@as(u8, 0)), .{zrx.discard()}),
    });
    var calls: usize = 0;
    try std.testing.expectError(error.ConfigurationFailed, run(.{ allocator, io, &calls, zrx.reader(failedReader) }, .{
        pipe(fromService(*zrx.Reader), .{ zrx.recover(forbiddenReaderRecovery), zrx.discard() }),
    }));
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectError(error.Canceled, run(.{ allocator, io, &calls, zrx.writer(canceledWriter) }, .{
        pipe(fromService(*zrx.Writer), .{ zrx.recover(forbiddenWriterRecovery), zrx.discard() }),
    }));
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "provider and endpoint acquisition failures release configuration dependencies" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing", "file" });
    defer allocator.free(missing);
    var tracking: TrackedIo = .{ .backend = .init(allocator, .{}) };
    defer tracking.backend.deinit();
    var trace: ConfigurationTrace = .{ .tracking = &tracking };
    inline for (.{ true, false }) |is_reader| {
        const recipe = if (is_reader) zrx.reader(readerConfig) else zrx.writer(writerConfig);
        const Source = if (is_reader) *zrx.Reader else *zrx.Writer;
        try std.testing.expectError(error.FileNotFound, run(.{
            allocator,
            tracking.asIo(),
            &trace,
            Paths{ .input = missing, .output = missing },
            zrx.resource({}, acquireSettings, releaseSettings),
            recipe,
        }, .{
            pipe(fromService(Source), .{zrx.discard()}),
        }));
        try std.testing.expect(!trace.alive);
        try std.testing.expect(trace.released_after_owners);
    }
    try std.testing.expectError(error.ConfigurationFailed, run(.{
        allocator,
        tracking.asIo(),
        &trace,
        Paths{ .input = missing, .output = missing },
        zrx.resource({}, acquireSettings, releaseSettings),
        zrx.reader(failedSettings),
    }, .{
        pipe(fromService(*zrx.Reader), .{zrx.discard()}),
    }));
    try std.testing.expectEqual(@as(usize, 3), trace.acquired);
    try std.testing.expectEqual(trace.acquired, trace.released);
    try std.testing.expect(trace.released_after_owners);
    try std.testing.expect(!trace.alive);
    try std.testing.expectEqual(@as(usize, 0), tracking.closes.load(.acquire));
}

const FileSettings = struct { path: []const u8 };
fn configuredFile(settings: FileSettings) zrx.Reader.Config {
    return .{ .file = settings.path };
}
fn configuredAllocation(gpa: std.mem.Allocator, path: []const u8) !void {
    var output: Captured = .{};
    try run(.{ gpa, io, FileSettings{ .path = path }, zrx.reader(configuredFile), &output }, .{
        pipe(fromService(*zrx.Reader), .{ flatMap(lines), forEach(capture) }),
    });
    try std.testing.expectEqual(@as(usize, 3), output.len);
}

test "provider-backed readers clean allocation and open failures" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(path);
    try std.testing.expectError(error.FileNotFound, configuredAllocation(allocator, path));
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\r\n\nxyz" });
    try std.testing.checkAllAllocationFailures(allocator, configuredAllocation, .{path});
}
