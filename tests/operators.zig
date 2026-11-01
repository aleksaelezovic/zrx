//! Current API coverage for bounds, retention, terminal storage and borrowed I/O.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const run = zrx.run;
const fromSlice = zrx.fromSlice;
const collectThen = zrx.collectThen;
const batchThen = zrx.batchThen;
const take = zrx.take;
const maxItems = zrx.maxItems;
const takeLast = zrx.takeLast;
const allocator = std.testing.allocator;
const io = std.testing.io;
const Saved = struct {
    items: [16]u32 = undefined,
    len: usize = 0,
    calls: usize = 0,
    sizes: [8]usize = undefined,
    fn copy(self: *@This(), items: []const u32) void {
        @memcpy(self.items[self.len..][0..items.len], items);
        self.len += items.len;
        self.sizes[self.calls] = items.len;
        self.calls += 1;
    }
    fn expect(self: *const @This(), items: []const u32) !void {
        try std.testing.expectEqualSlices(u32, items, self.items[0..self.len]);
    }
};

test "suffix retention handles empty zero short and wrapped rings" {
    const input = fromSlice(&[_]u32{ 1, 2, 3, 4, 5 });
    for ([_]usize{ 0, 2, 8 }) |limit| {
        var saved: Saved = .{};
        try run(.{ allocator, io, &saved }, .{pipe(&input, .{ takeLast(limit), collectThen(Saved.copy) })});
        const expected: []const u32 = switch (limit) {
            0 => &.{},
            2 => &.{ 4, 5 },
            else => &.{ 1, 2, 3, 4, 5 },
        };
        try saved.expect(expected);
        try std.testing.expectEqual(@as(usize, 1), saved.calls);
    }
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved }, .{
        pipe(fromSlice(&[_]u32{}), .{ takeLast(2), collectThen(Saved.copy) }),
    });
    try saved.expect(&.{});
}

const Cursor = struct {
    probes: u32 = 0,
    pub fn next(self: *@This()) ?u32 {
        self.probes += 1;
        return if (self.probes <= 5) self.probes else null;
    }
};
test "take avoids another probe while maxItems consumes the first excess item" {
    var cursor: Cursor = .{};
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved }, .{
        pipe(zrx.fromIterator(&cursor), .{ take(2), collectThen(Saved.copy) }),
    });
    try saved.expect(&.{ 1, 2 });
    try std.testing.expectEqual(@as(u32, 2), cursor.probes);
    saved = .{};
    try std.testing.expectError(error.TooManyItems, run(.{ allocator, io, &saved }, .{
        pipe(zrx.fromIterator(&cursor), .{ maxItems(1), collectThen(Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(u32, 4), cursor.probes);
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

test "batching flushes only a nonempty partial successful batch" {
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3, 4, 5 }), .{batchThen(2, Saved.copy)}),
    });
    try saved.expect(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 1 }, saved.sizes[0..saved.calls]);
    saved = .{};
    try run(.{ allocator, io, &saved }, .{
        pipe(fromSlice(&[_]u32{}), .{batchThen(2, Saved.copy)}),
    });
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
}

fn broken(output: *zrx.Emitter(u32)) !void {
    for ([_]u32{ 1, 2, 3 }) |item| try output.push(item);
    return error.Broken;
}
test "source errors suppress collection and suffixes but retain earlier batch effects" {
    const source = zrx.Stream(u32).fromProducer(1, broken);
    var saved: Saved = .{};
    try std.testing.expectError(error.Broken, run(.{ allocator, io, &saved }, .{
        pipe(&source, .{collectThen(Saved.copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try std.testing.expectError(error.Broken, run(.{ allocator, io, &saved }, .{
        pipe(&source, .{ takeLast(2), collectThen(Saved.copy) }),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    try std.testing.expectError(error.Broken, run(.{ allocator, io, &saved }, .{
        pipe(&source, .{batchThen(2, Saved.copy)}),
    }));
    try saved.expect(&.{ 1, 2 });
}

fn mustStayCold(_: *zrx.Emitter(u32)) void {
    @panic("invalid batch configuration must not activate a producer");
}
test "zero batch size fails before producer activation" {
    var saved: Saved = .{};
    const source = zrx.Stream(u32).fromProducer(1, mustStayCold);
    try std.testing.expectError(error.InvalidBatchSize, run(.{ allocator, io, &saved }, .{
        pipe(&source, .{batchThen(0, Saved.copy)}),
    }));
}

fn allocated(gpa: std.mem.Allocator) !void {
    var saved: Saved = .{};
    try run(.{ gpa, io, &saved }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3, 4, 5 }), .{ takeLast(3), batchThen(2, Saved.copy) }),
    });
    try saved.expect(&.{ 3, 4, 5 });
}
test "all retention and batch preparation allocation failures unwind storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocated, .{});
}

test "borrowed queue declaration is cold and uses run supplied Io" {
    var backing: [3]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&backing);
    try queue.putOne(io, 7);
    try queue.putOne(io, 9);
    queue.close(io);
    const input = zrx.readFrom(&queue);
    var saved: Saved = .{};
    try run(.{ allocator, io, &saved }, .{pipe(&input, .{collectThen(Saved.copy)})});
    try saved.expect(&.{ 7, 9 });
}

test "vector values remain whole items under grouped map callbacks" {
    const V = @Vector(4, u32);
    const Helpers = struct {
        fn double(v: V) V {
            return v * @as(V, @splat(2));
        }
        fn increment(v: V) V {
            return v + @as(V, @splat(1));
        }
        fn check(v: V) !void {
            try std.testing.expectEqual(@as(V, .{ 3, 5, 7, 9 }), v);
        }
    };
    try run(.{ allocator, io }, .{
        pipe(zrx.fromValue(@as(V, .{ 1, 2, 3, 4 })), .{ zrx.map(.{ Helpers.double, Helpers.increment }), zrx.forEach(Helpers.check) }),
    });
}

const Lines = struct {
    items: [8]zrx.Line(4) = undefined,
    len: usize = 0,
    fn copy(self: *@This(), items: []const zrx.Line(4)) void {
        @memcpy(self.items[0..items.len], items);
        self.len = items.len;
    }
};
test "run-owned line input preserves empty CR and final unterminated records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "a\n\nxy\r\nlast" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "input" });
    defer allocator.free(path);
    var saved: Lines = .{};
    try run(.{ allocator, io, &saved }, .{pipe(zrx.fileLines(path, 4, 1), .{collectThen(Lines.copy)})});
    try std.testing.expectEqual(@as(usize, 4), saved.len);
    for ([_][]const u8{ "a", "", "xy\r", "last" }, 0..) |expected, i|
        try std.testing.expectEqualStrings(expected, saved.items[i].bytes[0..saved.items[i].len]);
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "excess" });
    saved = .{};
    try std.testing.expectError(error.LineTooLong, run(.{ allocator, io, &saved }, .{
        pipe(zrx.fileLines(path, 4, 1), .{collectThen(Lines.copy)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), saved.len);
}

test "TCP prefix completes while its finite loopback peer remains open" {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const Listener = @TypeOf(listener);
    const Peer = struct {
        listener: *Listener,
        gate: std.Io.Event = .unset,
        stopped: std.atomic.Value(bool) = .init(false),
        fn serve(self: *@This()) !void {
            defer self.stopped.store(true, .release);
            const connection = try self.listener.accept(io);
            defer connection.close(io);
            var buffer: [32]u8 = undefined;
            var writer = connection.writer(io, &buffer);
            try writer.interface.writeAll("a\nb\n");
            try writer.interface.flush();
            try self.gate.wait(io);
        }
    };
    const Runner = struct {
        address: std.Io.net.IpAddress,
        saved: Lines = .{},
        done: std.Io.Event = .unset,
        fn execute(self: *@This()) !void {
            defer self.done.set(io);
            try run(.{ allocator, io, &self.saved }, .{
                pipe(zrx.tcpLines(self.address, 4, 1), .{ take(2), collectThen(Lines.copy) }),
            });
        }
    };
    var peer: Peer = .{ .listener = &listener };
    var serving = try io.concurrent(Peer.serve, .{&peer});
    defer serving.cancel(io) catch {};
    var runner: Runner = .{ .address = listener.socket.address };
    var running = try io.concurrent(Runner.execute, .{&runner});
    defer running.cancel(io) catch {};
    try runner.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try running.await(io);
    try std.testing.expectEqual(@as(usize, 2), runner.saved.len);
    try std.testing.expectEqualStrings("a", runner.saved.items[0].bytes[0..runner.saved.items[0].len]);
    try std.testing.expectEqualStrings("b", runner.saved.items[1].bytes[0..runner.saved.items[1].len]);
    try std.testing.expect(!peer.stopped.load(.acquire));
    try std.testing.expectError(error.Canceled, serving.cancel(io));
    try std.testing.expect(peer.stopped.load(.acquire));
}

test "textual I/O path conflicts fail before creating or truncating files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "output" });
    defer allocator.free(path);
    const empty = fromSlice(&[_]zrx.Line(4){});
    try std.testing.expectError(error.ConflictingIoPaths, run(.{ allocator, io }, .{
        pipe(&empty, .{zrx.writeFileLines(path, .{})}),
        pipe(&empty, .{zrx.writeFileLines(path, .{})}),
    }));
    if (tmp.dir.openFile(io, "output", .{})) |file| {
        file.close(io);
        return error.UnexpectedOutputCreated;
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
    try tmp.dir.writeFile(io, .{ .sub_path = "output", .data = "untouched\n" });
    try std.testing.expectError(error.ConflictingIoPaths, run(.{ allocator, io }, .{
        pipe(zrx.fileLines(path, 16, 1), .{zrx.writeFileLines(path, .{})}),
    }));
    const bytes = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(64));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("untouched\n", bytes);
}

test "empty selected outputs create once and exclusive reruns preserve the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "output" });
    defer allocator.free(path);
    const flow = pipe(fromSlice(&[_]zrx.Line(4){}), .{zrx.writeFileLines(path, .{ .exclusive = true })});
    try run(.{ allocator, io }, .{flow});
    try std.testing.expectError(error.PathAlreadyExists, run(.{ allocator, io }, .{flow}));
    const bytes = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(64));
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

fn fileAllocations(gpa: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "first\nlast" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const input = try std.fs.path.join(allocator, &.{ directory, "input" });
    defer allocator.free(input);
    const output = try std.fs.path.join(allocator, &.{ directory, "output" });
    defer allocator.free(output);
    try run(.{ gpa, io }, .{
        pipe(zrx.fileLines(input, 8, 1), .{zrx.writeFileLines(output, .{})}),
    });
    const bytes = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(64));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("first\nlast\n", bytes);
}
test "file graph allocation failures release partial readers writers and resources" {
    try std.testing.checkAllAllocationFailures(allocator, fileAllocations, .{});
}
