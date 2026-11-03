const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromSlice = zrx.fromSlice;
const fromValue = zrx.fromValue;
const readChunks = zrx.readChunks;
const splitBy = zrx.splitBy;
const flatten = zrx.flatten;
const map = zrx.map;
const forEach = zrx.forEach;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;
const Text = zrx.Chunk(u8, 8);

const Captured = struct {
    values: [32]Text = undefined,
    len: usize = 0,

    fn expect(self: *const Captured, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.len);
        for (expected, self.values[0..self.len]) |want, *actual|
            try std.testing.expectEqualStrings(want, actual.slice());
    }
};
fn capture(result: *Captured, item: Text) void {
    result.values[result.len] = item;
    result.len += 1;
}

test "splitBy is invariant to every chunk boundary and owns published frames" {
    const bytes = "\na\n\n12345678\nlast";
    for (0..bytes.len + 1) |boundary| {
        const pieces = [_][]const u8{ bytes[0..boundary], "", bytes[boundary..] };
        var result: Captured = .{};
        const source = pipe(fromSlice(&pieces), .{splitBy('\n', .{ .max_items = 8 })});
        // Fresh state each run; snapshots must not point into the changing frame.
        for (0..2) |_| {
            result.len = 0;
            try run(.{ allocator, io, &result }, .{pipe(source, .{forEach(capture)})});
            try result.expect(&.{ "", "a", "", "12345678", "last" });
        }
    }
}

const Separators = struct { other: u8 };
fn whitespace(config: Separators, value: u8) bool {
    return std.ascii.isWhitespace(value) or value == config.other;
}

test "splitBy typed predicate injects services and can tokenize whitespace" {
    var reader: std.Io.Reader = .fixed(" \talpha|be ta\nlast ");
    var result: Captured = .{};
    const source = pipe(readChunks(3, &reader), .{
        splitBy(whitespace, .{ .max_items = 8, .empty = .skip }),
    });
    try run(.{ allocator, io, Separators{ .other = '|' }, &result }, .{pipe(source, .{forEach(capture)})});
    try result.expect(&.{ "alpha", "be", "ta", "last" });
}

test "splitBy empty and final policies do not invent an item after delimiters" {
    for ([_][]const u8{ "", "\n", "\n\n", "tail", "a\n" }) |input| {
        var result: Captured = .{};
        const pieces = [_][]const u8{input};
        try run(.{ allocator, io, &result }, .{pipe(fromSlice(&pieces), .{
            splitBy('\n', .{ .max_items = 8, .empty = .skip, .final = .discard }),
            forEach(capture),
        })});
        try result.expect(if (std.mem.eql(u8, input, "a\n")) &.{"a"} else &.{});
    }
}

const Integers = struct { values: [6]u16 = undefined, len: usize = 0 };
fn captureInteger(result: *Integers, item: u16) void {
    result.values[result.len] = item;
    result.len += 1;
}
fn pair(value: u16) [2]u16 {
    return .{ value, value + 1 };
}

fn maybePair(value: u16) error{Bad}![2]u16 {
    if (value == 2) return error.Bad;
    return pair(value);
}
fn recoverElement(_: error{Bad}) u16 {
    return 99;
}

test "flatten forwards a pending error and resumes at the next outer item" {
    const values = [_]u16{ 1, 2, 3 };
    var result: Integers = .{};
    try run(.{ allocator, io, &result }, .{pipe(fromSlice(&values), .{
        map(maybePair), flatten(), zrx.recover(recoverElement), forEach(captureInteger),
    })});
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 99, 3, 4 }, result.values[0..result.len]);
}

test "flatten owns callback-produced arrays and supports slices and Chunks" {
    var result: Integers = .{};
    const values = [_]u16{ 10, 20 };
    try run(.{ allocator, io, &result }, .{pipe(fromSlice(&values), .{
        map(pair), flatten(), forEach(captureInteger),
    })});
    try std.testing.expectEqualSlices(u16, &.{ 10, 11, 20, 21 }, result.values[0..result.len]);
    result.len = 0;
    const slices = [_][]const u16{ &.{}, &.{ 1, 2 }, &.{}, &.{3} };
    try run(.{ allocator, io, &result }, .{pipe(fromSlice(&slices), .{ flatten(), forEach(captureInteger) })});
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, result.values[0..result.len]);
    result.len = 0;
    const chunks = [_]zrx.Chunk(u16, 4){
        try .fromSlice(&.{ 1, 0, 2 }), try .fromSlice(&.{ 3, 0 }),
    };
    // Generalized framing is over elements, not just byte strings.
    try run(.{ allocator, io, &result }, .{pipe(fromSlice(&chunks), .{
        splitBy(@as(u16, 0), .{ .max_items = 4 }), flatten(), forEach(captureInteger),
    })});
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, result.values[0..result.len]);
}

test "string literal pointer arrays can be framed without another wrapper" {
    var output: Captured = .{};
    try run(.{ allocator, io, &output }, .{pipe(fromValue("one,two"), .{
        splitBy(',', .{ .max_items = 8 }), forEach(capture),
    })});
    try output.expect(&.{ "one", "two" });
}

const Probes = struct { count: usize = 0 };
fn probe(probes: *Probes, _: []const u8) void {
    probes.count += 1;
}
fn fail(value: []const u8) error{Bad}![]const u8 {
    return if (std.mem.eql(u8, value, "bad")) error.Bad else value;
}
fn recoverFrame(_: error{Bad}) Text {
    return Text.fromSlice("failed") catch unreachable;
}
fn recoverBound(_: error{FrameTooLong}) Text {
    return Text.fromSlice("excess") catch unreachable;
}

test "splitBy discards unfinished state and stops at first pending upstream error" {
    const pieces = [_][]const u8{ "ok\npartial", "bad", "unprobed\n" };
    var probes: Probes = .{};
    var result: Captured = .{};
    try run(.{ allocator, io, &probes, &result }, .{pipe(fromSlice(&pieces), .{
        zrx.tap(probe),
        map(fail),
        splitBy('\n', .{ .max_items = 8 }),
        zrx.recover(recoverFrame),
        forEach(capture),
    })});
    try result.expect(&.{ "ok", "failed" });
    try std.testing.expectEqual(@as(usize, 2), probes.count);
}

test "splitBy length overflow is pending recoverable and never probes another chunk" {
    const pieces = [_][]const u8{ "12345678", "9\n", "unprobed\n" };
    var probes: Probes = .{};
    var result: Captured = .{};
    try run(.{ allocator, io, &probes, &result }, .{pipe(fromSlice(&pieces), .{
        zrx.tap(probe),
        splitBy('\n', .{ .max_items = 8 }),
        zrx.recover(recoverBound),
        forEach(capture),
    })});
    try result.expect(&.{"excess"});
    try std.testing.expectEqual(@as(usize, 2), probes.count);
}

fn forbidden(_: anyerror) Text {
    @panic("source/control failure reached operation recovery");
}

test "readChunks preserves standard native errors and cancellation as control" {
    for ([_]std.Io.File.Reader.Error{ error.InputOutput, error.Canceled }) |failure| {
        var reader: std.Io.File.Reader = .{
            .io = io,
            .file = .stdin(),
            .interface = .failing,
            .err = failure,
        };
        try std.testing.expectError(failure, run(.{ allocator, io }, .{pipe(readChunks(3, &reader), .{
            splitBy('\n', .{ .max_items = 8 }), zrx.recover(forbidden), zrx.discard(),
        })}));
    }
}

// A finite source with exact probes lets us distinguish normal EOF from source
// failure, and prove that take does not request another chunk or flush a tail.
const Script = struct {
    pub const Item = []const u8;
    probes: usize = 0,
    failure: bool = false,
    pub fn iterator(self: *Script) *Script {
        return self;
    }
    pub fn next(self: *Script) error{Broken}!?[]const u8 {
        self.probes += 1;
        if (self.probes == 1) return "one\npartial";
        if (self.failure) return error.Broken;
        return null;
    }
};

test "source failure suppresses final frame and take retires without another probe" {
    var script: Script = .{ .failure = true };
    var result: Captured = .{};
    try std.testing.expectError(error.Broken, run(.{ allocator, io, &result }, .{pipe(zrx.fromIterator(&script), .{
        splitBy('\n', .{ .max_items = 8 }), zrx.recover(forbidden), forEach(capture),
    })}));
    try result.expect(&.{"one"});
    script.probes = 0;
    result.len = 0;
    try run(.{ allocator, io, &result }, .{pipe(zrx.fromIterator(&script), .{
        splitBy('\n', .{ .max_items = 8 }), zrx.take(1), forEach(capture),
    })});
    try result.expect(&.{"one"});
    try std.testing.expectEqual(@as(usize, 1), script.probes);
}

test "readChunks and flatten round-trip exact bytes through a standard writer" {
    var reader: std.Io.Reader = .fixed("a\n\x00b\r\nlast");
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try run(.{ allocator, io }, .{pipe(readChunks(3, &reader), .{ flatten(), zrx.writeTo(&writer) })});
    try std.testing.expectEqualStrings("a\n\x00b\r\nlast", writer.buffered());
}

test "writeTo handles chunk values without adding delimiters" {
    var reader: std.Io.Reader = .fixed("bytes not lines");
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try run(.{ allocator, io }, .{pipe(readChunks(4, &reader), .{zrx.writeTo(&writer)})});
    try std.testing.expectEqualStrings("bytes not lines", writer.buffered());
}

fn expandReader(reader: *zrx.Reader) @TypeOf(readChunks(4, @as(*zrx.Reader, undefined))) {
    return readChunks(4, reader);
}

test "byte streams compose managed readers and injected managed writer terminals" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const content = "unchanged\n\x00bytes without final LF";
    try temp.dir.writeFile(io, .{ .sub_path = "input", .data = content });
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const input = try std.fs.path.join(allocator, &.{ root, "input" });
    defer allocator.free(input);
    const output = try std.fs.path.join(allocator, &.{ root, "output" });
    defer allocator.free(output);
    const flow = pipe(zrx.fromService(*zrx.Reader), .{
        zrx.flatMap(expandReader), zrx.writeTo(*zrx.Writer),
    });
    const bindings = .{
        allocator,
        io,
        zrx.reader(.{ .file = input }),
        zrx.writer(.{ .file = .{ .path = output, .options = .{ .exclusive = true } } }),
    };
    try run(bindings, .{flow});
    const actual = try temp.dir.readFileAlloc(io, "output", allocator, .limited(128));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(content, actual);
    try std.testing.expectError(error.PathAlreadyExists, run(bindings, .{flow}));
}

const Shared = struct { left: Captured = .{}, right: Captured = .{} };
fn left(result: *Shared, items: []const Text) void {
    for (items) |item| capture(&result.left, item);
}
fn right(result: *Shared, items: []const Text) void {
    for (items) |item| capture(&result.right, item);
}

test "shared framing evaluates once and keeps snapshots independent across users" {
    var reader: std.Io.Reader = .fixed("a\nbb\nccc\n");
    var output: Shared = .{};
    const source = pipe(readChunks(2, &reader), .{splitBy('\n', .{ .max_items = 8 })});
    try run(.{ allocator, io, &output }, .{
        pipe(&source, .{zrx.collectThen(left)}), pipe(&source, .{zrx.collectThen(right)}),
    });
    try output.left.expect(&.{ "a", "bb", "ccc" });
    try output.right.expect(&.{ "a", "bb", "ccc" });
}

fn framingAllocation(gpa: std.mem.Allocator) !void {
    var reader: std.Io.Reader = .fixed("a\nbb\nccc");
    var output: Captured = .{};
    const source = pipe(readChunks(2, &reader), .{splitBy('\n', .{ .max_items = 8 })});
    try run(.{ gpa, io, &output }, .{
        pipe(source, .{forEach(capture)}),
    });
    try output.expect(&.{ "a", "bb", "ccc" });
}

test "framing cleans up every cold allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, framingAllocation, .{});
}

const ShortReads = struct {
    reader: std.Io.Reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = stream, .readVec = readVec } },
    probes: usize = 0,
    fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
        @panic("readChunks should use readVec");
    }
    fn readVec(reader: *std.Io.Reader, buffers: [][]u8) std.Io.Reader.Error!usize {
        const self: *ShortReads = @fieldParentPtr("reader", reader);
        self.probes += 1;
        // Zero is not EOF. A short read must publish without filling the chunk.
        switch (self.probes) {
            1 => return 0,
            2 => {
                buffers[0][0] = 'x';
                return 1;
            },
            else => return error.EndOfStream,
        }
    }
};

test "readChunks accepts zero and short reads without treating zero as EOF" {
    var source: ShortReads = .{};
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try run(.{ allocator, io }, .{pipe(readChunks(8, &source.reader), .{ zrx.take(1), zrx.writeTo(&writer) })});
    try std.testing.expectEqualStrings("x", writer.buffered());
    try std.testing.expectEqual(@as(usize, 2), source.probes);
}

const FlushProbe = struct {
    writer: std.Io.Writer = undefined,
    buffer: [64]u8 = undefined,
    flushes: usize = 0,
    fail_flush: bool = false,
    fn init(self: *FlushProbe) void {
        self.writer = .{ .buffer = &self.buffer, .vtable = &.{ .drain = drain, .flush = flush } };
    }
    fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        @panic("test payload must fit the buffer");
    }
    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushProbe = @fieldParentPtr("writer", writer);
        self.flushes += 1;
        if (self.fail_flush) return error.WriteFailed;
        writer.end = 0;
    }
};

test "byte terminal flushes only at successful end and propagates flush failure" {
    const chunks = [_][]const u8{ "one", "two" };
    for ([_]bool{ false, true }) |fail_flush| {
        var output: FlushProbe = .{ .fail_flush = fail_flush };
        output.init();
        const result = run(.{ allocator, io }, .{pipe(fromSlice(&chunks), .{zrx.writeTo(&output.writer)})});
        if (fail_flush) try std.testing.expectError(error.WriteFailed, result) else try result;
        try std.testing.expectEqual(@as(usize, 1), output.flushes);
    }
    var output: FlushProbe = .{};
    output.init();
    const failing = [_][]const u8{ "ok", "bad", "later" };
    try std.testing.expectError(error.Bad, run(.{ allocator, io }, .{pipe(fromSlice(&failing), .{
        map(fail), zrx.writeTo(&output.writer),
    })}));
    try std.testing.expectEqual(@as(usize, 0), output.flushes);
}
