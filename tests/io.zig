const std = @import("std");
const testing_api = @import("zrx");
const zrx = testing_api.io_api;
const records = testing_api.line_records;
const resources = testing_api.resources;
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const Line = zrx.Line;
const line = zrx.line;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const fileLines = zrx.fileLines;
const tcpLines = zrx.tcpLines;
const writeFileLines = zrx.writeFileLines;
const forEach = zrx.forEach;
const collectThenWith = zrx.collectThenWith;
const takeLast = zrx.takeLast;
const take = zrx.take;
const stdoutLines = zrx.stdoutLines;
const stdinLines = zrx.stdinLines;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn temporaryPath(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

fn Saved(comptime maxBytes: usize) type {
    return struct {
        values: [16]Line(maxBytes) = undefined,
        len: usize = 0,
        fn copy(self: *@This(), values: []const Line(maxBytes)) !void {
            if (values.len > self.values.len) return error.NoSpaceLeft;
            @memcpy(self.values[0..values.len], values);
            self.len = values.len;
        }
        fn expect(self: *@This(), values: []const []const u8) !void {
            try std.testing.expectEqual(values.len, self.len);
            for (values, self.values[0..self.len]) |expected, actual|
                try std.testing.expectEqualStrings(expected, actual.bytes[0..actual.len]);
        }
    };
}

test "line framing preserves bytes and treats only LF as delimiter" {
    var reader = std.Io.Reader.fixed("\nabc\r\nx\x00\xff\nlast");
    const cases = [_][]const u8{ "", "abc\r", "x\x00\xff", "last" };
    for (cases) |expected| {
        const value = (try records.next(4, &reader, io)).?;
        try std.testing.expectEqualStrings(expected, value.bytes[0..value.len]);
    }
    try std.testing.expectEqual(null, try records.next(4, &reader, io));
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectEqual(null, try records.next(4, &empty, io));
    var trailing = std.Io.Reader.fixed("a\n");
    _ = try records.next(4, &trailing, io);
    try std.testing.expectEqual(null, try records.next(4, &trailing, io));
}

test "exact line bound accepts LF and EOF and excess never emits" {
    var delimited = std.Io.Reader.fixed("abcd\n");
    try std.testing.expectEqual(@as(usize, 4), (try records.next(4, &delimited, io)).?.len);
    var eof = std.Io.Reader.fixed("abcd");
    try std.testing.expectEqual(@as(usize, 4), (try records.next(4, &eof, io)).?.len);
    var excess = std.Io.Reader.fixed("abcde\n");
    try std.testing.expectError(error.LineTooLong, records.next(4, &excess, io));
    try std.testing.expectError(error.LineTooLong, line(4, "abcde"));
}

test "reader failure after a partial record is not successful EOF" {
    var reader: std.Io.Reader = .failing;
    var partial = [_]u8{ 'a', 'b' };
    reader.buffer = &partial;
    reader.end = partial.len;
    try std.testing.expectError(error.ReadFailed, records.next(4, &reader, io));
}

test "one-byte reader refills do not change framing or mutate previous items" {
    const Fragmented = struct {
        reader: std.Io.Reader,
        data: []const u8,
        position: usize = 0,
        fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *@This() = @fieldParentPtr("reader", reader);
            if (self.position == self.data.len) return error.EndOfStream;
            var byte = [_]u8{self.data[self.position]};
            const bytes = limit.slice(&byte);
            try writer.writeAll(bytes);
            self.position += bytes.len;
            return bytes.len;
        }
    };
    var buffer: [1]u8 = undefined;
    var input: Fragmented = .{
        .reader = .{ .vtable = &.{ .stream = Fragmented.stream }, .buffer = &buffer, .seek = 0, .end = 0 },
        .data = "abcd\nxy",
    };
    const first = (try records.next(4, &input.reader, io)).?;
    const second = (try records.next(4, &input.reader, io)).?;
    try std.testing.expectEqualStrings("abcd", first.bytes[0..first.len]);
    try std.testing.expectEqualStrings("xy", second.bytes[0..second.len]);
    try std.testing.expectEqual(null, try records.next(4, &input.reader, io));
}

test "line writing appends LF and observes flush failure" {
    const Helpers = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try records.write(&output.writer, try line(4, "abc"));
    try std.testing.expectEqualStrings("abc\n", output.written());
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .{
        .vtable = &.{ .drain = Helpers.drain, .flush = Helpers.flush },
        .buffer = &buffer,
    };
    try std.testing.expectError(error.WriteFailed, records.write(&writer, try line(4, "abc")));
    var invalid: Line(4) = .{ .len = 5 };
    try std.testing.expectError(error.InvalidLineLength, records.write(&writer, invalid));
    invalid.len = 0;
}

test "resource slots release only acquired resources in reverse order" {
    const State = struct { events: [8]u8 = undefined, count: usize = 0 };
    const Resource = struct {
        state: *State,
        id: u8,
        fail: bool = false,
        pub fn acquire(self: *@This(), _: std.Io) !void {
            if (self.fail) return error.AcquireFailed;
            self.state.events[self.state.count] = self.id;
            self.state.count += 1;
        }
        pub fn release(self: *@This(), _: std.Io) void {
            self.state.events[self.state.count] = self.id + 10;
            self.state.count += 1;
        }
    };
    var state: State = .{};
    var scope: resources.Scope = .{ .allocator = allocator, .io = io };
    _ = try scope.add(Resource, .{ .state = &state, .id = 1 }, null);
    _ = try scope.add(Resource, .{ .state = &state, .id = 2 }, null);
    _ = try scope.add(Resource, .{ .state = &state, .id = 3, .fail = true }, null);
    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectError(error.AcquireFailed, scope.acquireAll());
    scope.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 12, 11 }, state.events[0..state.count]);
}

test "file declarations stay cold and a shared read retains independent values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "input");
    defer allocator.free(input_path);
    const output_path = try temporaryPath(&tmp, "output");
    defer allocator.free(output_path);
    const input = fileLines(input_path, 4, 1);
    var all: Saved(4) = .{};
    var suffix: Saved(4) = .{};
    const output = pipe(&input, .{writeFileLines(output_path, .{ .exclusive = true })});
    const capture = pipe(&input, .{collectThenWith(&all, Saved(4).copy)});
    const retained = pipe(&input, .{ takeLast(2), collectThenWith(&suffix, Saved(4).copy) });
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "output", .{}));
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\nbb\nccc" });
    try run(allocator, io, .{ output, capture, retained });
    try all.expect(&.{ "a", "bb", "ccc" });
    try suffix.expect(&.{ "bb", "ccc" });
    const bytes = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(128));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("a\nbb\nccc\n", bytes);
    // The source is reopened, not exhausted or replaying cached transport.
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "new\n" });
    try run(allocator, io, .{capture});
    try all.expect(&.{"new"});
    try std.testing.expectError(error.PathAlreadyExists, run(allocator, io, .{output}));
}

test "empty selected output is created and unreachable input is not opened" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_path = try temporaryPath(&tmp, "empty");
    defer allocator.free(output_path);
    const unused = fileLines("this-file-must-not-exist", 4, 1);
    _ = unused;
    const values: []const Line(4) = &.{};
    try run(allocator, io, .{pipe(values, .{writeFileLines(output_path, .{ .exclusive = true })})});
    const bytes = try tmp.dir.readFileAlloc(io, "empty", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "an absent input does not create its dependent output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "absent");
    defer allocator.free(input_path);
    const output_path = try temporaryPath(&tmp, "output");
    defer allocator.free(output_path);
    const input = fileLines(input_path, 4, 1);
    try std.testing.expectError(error.FileNotFound, run(allocator, io, .{
        pipe(&input, .{writeFileLines(output_path, .{ .exclusive = true })}),
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "output", .{}));
}

test "take zero still acquires selected files but never reads their content" {
    const Probe = struct {
        var reads: std.atomic.Value(usize) = .init(0);
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_read_streaming) _ = reads.fetchAdd(1, .monotonic);
            return io.vtable.operate(userdata, operation);
        }
    };
    Probe.reads.store(0, .monotonic);
    var table = io.vtable.*;
    table.operate = Probe.operate;
    const observed: std.Io = .{ .vtable = &table, .userdata = io.userdata };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "input");
    defer allocator.free(input_path);
    const output_path = try temporaryPath(&tmp, "output");
    defer allocator.free(output_path);
    const input = fileLines(input_path, 4, 1);
    const flow = pipe(&input, .{ take(0), writeFileLines(output_path, .{ .exclusive = true }) });
    try std.testing.expectError(error.FileNotFound, run(allocator, observed, .{flow}));
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "abc\n" });
    try run(allocator, observed, .{flow});
    try std.testing.expectEqual(@as(usize, 0), Probe.reads.load(.monotonic));
    const output = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(16));
    defer allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "standard output wrappers do not own or close process handles" {
    const Probe = struct {
        var closes: std.atomic.Value(usize) = .init(0);
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            _ = closes.fetchAdd(files.len, .monotonic);
            io.vtable.fileClose(userdata, files);
        }
    };
    Probe.closes.store(0, .monotonic);
    var table = io.vtable.*;
    table.fileClose = Probe.close;
    const observed: std.Io = .{ .vtable = &table, .userdata = io.userdata };
    const empty: []const Line(4) = &.{};
    try run(allocator, observed, .{pipe(empty, .{stdoutLines()})});
    try std.testing.expectEqual(@as(usize, 0), Probe.closes.load(.monotonic));
}

test "endpoint conflicts and zero capacity fail before acquisition" {
    const empty: []const Line(4) = &.{};
    try std.testing.expectError(error.DuplicateIoEndpoint, run(allocator, io, .{
        pipe(empty, .{stdoutLines()}),
        pipe(empty, .{stdoutLines()}),
    }));
    const source = fileLines("absent", 4, 0);
    try std.testing.expectError(error.UnsupportedCapacity, run(allocator, io, .{
        pipe(&source, .{writeFileLines("must-not-be-created", .{ .exclusive = true })}),
    }));
    const alias = fileLines("same", 4, 1);
    try std.testing.expectError(error.ConflictingIoPaths, run(allocator, io, .{
        pipe(&alias, .{writeFileLines("same", .{ .exclusive = true })}),
    }));
    const Helpers = struct {
        fn ignore(_: Line(4)) void {}
    };
    const first = stdinLines(4, 1);
    const second = stdinLines(4, 1);
    try std.testing.expectError(error.DuplicateIoEndpoint, run(allocator, io, .{
        pipe(&first, .{forEach(Helpers.ignore)}),
        pipe(&second, .{forEach(Helpers.ignore)}),
    }));
}

test "worker startup failure performs no file acquisition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_path = try temporaryPath(&tmp, "cold");
    defer allocator.free(output_path);
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    const empty: []const Line(4) = &.{};
    const Helpers = struct {
        fn ignore(_: Line(4)) void {}
    };
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{
        pipe(empty, .{writeFileLines(output_path, .{ .exclusive = true })}),
        pipe(empty, .{forEach(Helpers.ignore)}),
    }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "cold", .{}));
}

test "acquisition failure gates callbacks and closes an already-created output" {
    const Probe = struct {
        var closes: std.atomic.Value(usize) = .init(0);
        var calls: std.atomic.Value(usize) = .init(0);
        fn produce(output: *Emitter(Line(4))) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(try line(4, "abc"));
        }
        fn ignore(_: Line(4)) void {}
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            _ = closes.fetchAdd(files.len, .monotonic);
            io.vtable.fileClose(userdata, files);
        }
    };
    Probe.closes.store(0, .monotonic);
    Probe.calls.store(0, .monotonic);
    var table = io.vtable.*;
    table.fileClose = Probe.close;
    const observed: std.Io = .{ .vtable = &table, .userdata = io.userdata };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "absent");
    defer allocator.free(input_path);
    const output_path = try temporaryPath(&tmp, "created");
    defer allocator.free(output_path);
    const input = Stream(Line(4)).fromProducer(1, Probe.produce);
    const missing = fileLines(input_path, 4, 1);
    try std.testing.expectError(error.FileNotFound, run(allocator, observed, .{
        pipe(&input, .{writeFileLines(output_path, .{ .exclusive = true })}),
        pipe(&missing, .{forEach(Probe.ignore)}),
    }));
    try std.testing.expectEqual(@as(usize, 1), Probe.closes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), Probe.calls.load(.monotonic));
    const bytes = try tmp.dir.readFileAlloc(io, "created", allocator, .limited(16));
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "backend write failure fails run and closes owned output" {
    const Probe = struct {
        var closes: std.atomic.Value(usize) = .init(0);
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return error.Canceled;
            return io.vtable.operate(userdata, operation);
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            _ = closes.fetchAdd(files.len, .monotonic);
            io.vtable.fileClose(userdata, files);
        }
    };
    Probe.closes.store(0, .monotonic);
    var table = io.vtable.*;
    table.operate = Probe.operate;
    table.fileClose = Probe.close;
    const failing: std.Io = .{ .vtable = &table, .userdata = io.userdata };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_path = try temporaryPath(&tmp, "failure");
    defer allocator.free(output_path);
    const input = [_]Line(4){try line(4, "abc")};
    try std.testing.expectError(error.Canceled, run(allocator, failing, .{
        pipe(&input, .{writeFileLines(output_path, .{ .exclusive = true })}),
    }));
    try std.testing.expectEqual(@as(usize, 1), Probe.closes.load(.monotonic));
}

fn allocationScenario(gpa: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const input = fileLines(input_path, 4, 1);
    try run(gpa, io, .{pipe(&input, .{writeFileLines(output_path, .{})})});
}

test "every preparation allocation failure cleans resource slots and transport" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "input");
    defer allocator.free(input_path);
    const output_path = try temporaryPath(&tmp, "output");
    defer allocator.free(output_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\nb" });
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{ input_path, output_path });
}

test "file framing is independent of 4096-byte reader buffers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "long");
    defer allocator.free(input_path);
    var text: [5001]u8 = @splat('x');
    text[5000] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "long", .data = &text });
    const source = fileLines(input_path, 5000, 1);
    var saved: Saved(5000) = .{};
    try run(allocator, io, .{pipe(&source, .{collectThenWith(&saved, Saved(5000).copy)})});
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expectEqualStrings(text[0..5000], saved.values[0].bytes[0..saved.values[0].len]);
}

test "excess input fails run and suppresses whole-input collection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input_path = try temporaryPath(&tmp, "excess");
    defer allocator.free(input_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "excess", .data = "ok\nexcess\n" });
    const source = fileLines(input_path, 4, 1);
    var saved: Saved(4) = .{};
    try std.testing.expectError(error.LineTooLong, run(allocator, io, .{
        pipe(&source, .{collectThenWith(&saved, Saved(4).copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.len);
}

test "TCP source handles fragmented records and EOF through a loopback peer" {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Peer = struct {
        fn send(listener: *std.Io.net.Server) !void {
            const connection = try listener.accept(io);
            defer connection.close(io);
            var buffer: [16]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("a");
            try writer.interface.flush();
            try writer.interface.writeAll("b\n\nlast");
            try writer.interface.flush();
        }
    };
    var task = try io.concurrent(Peer.send, .{&server});
    defer task.cancel(io) catch {};
    const input = tcpLines(server.socket.address, 4, 1);
    var saved: Saved(4) = .{};
    try run(allocator, io, .{pipe(&input, .{collectThenWith(&saved, Saved(4).copy)})});
    try task.await(io);
    try saved.expect(&.{ "ab", "", "last" });
}

test "canceling a blocked TCP run joins its reader before closing the socket" {
    const State = struct {
        server: *std.Io.net.Server,
        accepted: std.Io.Event = .unset,
        saw_close: bool = false,
    };
    const Helpers = struct {
        fn peer(state: *State) !void {
            const connection = try state.server.accept(io);
            defer connection.close(io);
            state.accepted.set(io);
            var buffer: [16]u8 = undefined;
            var reader = connection.reader(io, &buffer);
            try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
            state.saw_close = true;
        }
        fn ignore(_: Line(4)) void {}
        fn execute(address: std.Io.net.IpAddress) !void {
            const input = tcpLines(address, 4, 1);
            try run(allocator, io, .{pipe(&input, .{forEach(ignore)})});
        }
    };
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var state: State = .{ .server = &server };
    var peer = try io.concurrent(Helpers.peer, .{&state});
    defer peer.cancel(io) catch {};
    var execution = try io.concurrent(Helpers.execute, .{server.socket.address});
    defer execution.cancel(io) catch {};
    try state.accepted.wait(io);
    try std.testing.expectError(error.Canceled, execution.cancel(io));
    try peer.await(io);
    try std.testing.expect(state.saw_close);
}
