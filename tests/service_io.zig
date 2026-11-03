const std = @import("std");
const builtin = @import("builtin");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromService = zrx.fromService;
const fromValue = zrx.fromValue;
const forEach = zrx.forEach;
const resource = zrx.resource;
const run = zrx.run;
const readerLines = zrx.readerLines;
const allocator = std.testing.allocator;
const io = std.testing.io;

test "bounded line type constructors preserve bytes and reject excess output" {
    const Text = zrx.Line(3);
    const copied = try Text.fromSlice("abc");
    const functional = try zrx.line(3, "abc");
    try std.testing.expectEqualDeep(functional, copied);
    const formatted = try Text.fromFormat("{s}", .{"abc"});
    try std.testing.expectEqualDeep(copied, formatted);
    const empty = try Text.fromFormat("", .{});
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.LineTooLong, Text.fromSlice("abcd"));
    try std.testing.expectError(error.LineTooLong, Text.fromFormat("{d}", .{@as(u32, 1000)}));
}

const Service = struct { value: u32 };
const Result = struct { left: u32 = 0, right: u32 = 0, acquired: u32 = 0, released: u32 = 0 };
fn acquire(result: *Result, _: void) Service {
    result.acquired += 1;
    return .{ .value = result.acquired };
}
fn release(result: *Result, service: Service) void {
    std.debug.assert(result.left == service.value and result.right == service.value);
    result.released += 1;
}
fn left(result: *Result, service: Service) void {
    result.left = service.value;
}
fn right(result: *Result, service: Service) void {
    result.right = service.value;
}

test "service source is cold and managed sharing acquires once per run" {
    var result: Result = .{};
    const source = fromService(Service);
    const recipe = resource({}, acquire, release);
    try std.testing.expectEqual(@as(u32, 0), result.acquired);
    for (1..3) |iteration| {
        try run(.{ allocator, io, &result, recipe }, .{
            pipe(&source, .{forEach(left)}),
            pipe(&source, .{forEach(right)}),
        });
        try std.testing.expectEqual(@as(u32, @intCast(iteration)), result.acquired);
        try std.testing.expectEqual(result.acquired, result.released);
    }
}

test "borrowed service source emits a shallow value and is not released" {
    var result: Result = .{};
    try run(.{ allocator, io, &result, Service{ .value = 42 } }, .{
        pipe(fromService(Service), .{forEach(left)}),
    });
    try std.testing.expectEqual(@as(u32, 42), result.left);
    try std.testing.expectEqual(@as(u32, 0), result.released);
}

const ErrorData = error{Bad}!u32;
fn inspectError(value: ErrorData) !void {
    try std.testing.expectError(error.Bad, value);
}
fn inspectOptional(value: ?u32) !void {
    try std.testing.expect(value == null);
}
fn pointer(result: *Result, service: *Service) void {
    service.value += 1;
    result.left = service.value;
}

test "service pointers are not dereferenced and optional/error unions stay data" {
    var value: Service = .{ .value = 4 };
    var result: Result = .{};
    try run(.{ allocator, io, &value, &result, @as(ErrorData, error.Bad), @as(?u32, null) }, .{
        pipe(fromService(*Service), .{forEach(pointer)}),
        pipe(fromService(ErrorData), .{forEach(inspectError)}),
        pipe(fromService(?u32), .{forEach(inspectOptional)}),
    });
    try std.testing.expectEqual(@as(u32, 5), value.value);
    try std.testing.expectEqual(value.value, result.left);
}

fn failedAcquire(_: void) error{AcquireFailed}!Service {
    return error.AcquireFailed;
}
fn noRelease(_: Service) void {
    @panic("failed acquisition must not release");
}
fn forbiddenRecover(_: anyerror) Service {
    @panic("acquisition error reached operation recovery");
}

test "service acquisition failure remains control and unused recipe stays cold" {
    try std.testing.expectError(error.AcquireFailed, run(.{ allocator, io, resource({}, failedAcquire, noRelease) }, .{
        pipe(fromService(Service), .{ zrx.recover(forbiddenRecover), zrx.discard() }),
    }));
    try run(.{ allocator, io, resource({}, failedAcquire, noRelease) }, .{
        pipe(fromValue(@as(u32, 1)), .{zrx.discard()}),
    });
}

fn rawArgs() std.process.Args {
    return switch (builtin.os.tag) {
        .windows => .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral("tool --name \"two words\"") },
        else => .{ .vector = &.{ "tool", "--name", "two words" } },
    };
}
fn inspectArgs(args: *zrx.Arguments) !void {
    try std.testing.expectEqual(@as(usize, 3), args.values.len);
    try std.testing.expectEqualStrings("tool", args.values[0]);
    try std.testing.expectEqualStrings("--name", args.values[1]);
    try std.testing.expectEqualStrings("two words", args.values[2]);
}
fn argumentsAllocation(gpa: std.mem.Allocator) !void {
    try run(.{ gpa, io, zrx.arguments(rawArgs()) }, .{
        pipe(fromService(*zrx.Arguments), .{forEach(inspectArgs)}),
    });
}

test "arguments own conversion storage, preserve argv0 and clean allocation failures" {
    try std.testing.checkAllAllocationFailures(allocator, argumentsAllocation, .{});
    var borrowed: zrx.Arguments = .{ .values = &.{ "tool", "--name", "two words" } };
    try run(.{ allocator, io, &borrowed }, .{
        pipe(fromService(*zrx.Arguments), .{forEach(inspectArgs)}),
    });
}

const Lines = struct { values: [3]zrx.Line(3) = undefined, len: usize = 0 };
fn capture(lines: *Lines, value: zrx.Line(3)) void {
    lines.values[lines.len] = value;
    lines.len += 1;
}
fn forbiddenReadRecovery(_: anyerror) zrx.Line(3) {
    @panic("source/control error reached recovery");
}

test "resource reader adapter reuses exact LF framing, CR data and final record" {
    var reader: std.Io.Reader = .fixed("a\r\n\nxyz");
    var lines: Lines = .{};
    try run(.{ allocator, io, &lines }, .{
        pipe(readerLines(3, &reader), .{forEach(capture)}),
    });
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    for ([_][]const u8{ "a\r", "", "xyz" }, 0..) |expected, index| {
        const value = lines.values[index];
        try std.testing.expectEqualStrings(expected, value.bytes[0..value.len]);
    }
    lines.len = 0;
    var empty: std.Io.Reader = .fixed("");
    try run(.{ allocator, io, &lines }, .{
        pipe(readerLines(3, &empty), .{forEach(capture)}),
    });
    try std.testing.expectEqual(@as(usize, 0), lines.len);
}

test "reader bounds and underlying failures remain source control" {
    var excess: std.Io.Reader = .fixed("abcd\n");
    try std.testing.expectError(error.LineTooLong, run(.{ allocator, io }, .{
        pipe(readerLines(3, &excess), .{ zrx.recover(forbiddenReadRecovery), zrx.discard() }),
    }));
    var broken_file: std.Io.File.Reader = .{
        .io = io,
        .file = .stdin(),
        .interface = .failing,
        .err = error.InputOutput,
    };
    try std.testing.expectError(error.InputOutput, run(.{ allocator, io }, .{
        pipe(readerLines(3, &broken_file), .{ zrx.recover(forbiddenReadRecovery), zrx.discard() }),
    }));
    broken_file.err = error.Canceled;
    try std.testing.expectError(error.Canceled, run(.{ allocator, io }, .{
        pipe(readerLines(3, &broken_file), .{ zrx.recover(forbiddenReadRecovery), zrx.discard() }),
    }));
    var broken: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, run(.{ allocator, io }, .{
        pipe(readerLines(3, &broken), .{zrx.discard()}),
    }));
}

fn writeText(writer: *zrx.Writer, _: u32) !void {
    try zrx.writeLine(writer, try zrx.line(8, "record"));
    try writer.write("summary\n");
    try writer.flush();
}

test "managed writer flushes exact text and lines and refuses overwrite" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const output = try std.fs.path.join(allocator, &.{ path, "output" });
    defer allocator.free(output);
    const writer = zrx.writer(.{ .file = .{ .path = output, .options = .{ .exclusive = true } } });
    try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, "output", .{}));
    try run(.{ allocator, io, writer }, .{pipe(fromValue(@as(u32, 1)), .{forEach(writeText)})});
    const bytes = try temp.dir.readFileAlloc(io, "output", allocator, .limited(128));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("record\nsummary\n", bytes);
    try std.testing.expectError(error.PathAlreadyExists, run(.{ allocator, io, writer }, .{
        pipe(fromValue(@as(u32, 1)), .{forEach(writeText)}),
    }));
}

test "writer validates lines and does not silently accept failed writes" {
    var writer: zrx.Writer = .{ .output = .stdout };
    writer.writer = .{ .io = io, .file = .stdout(), .interface = .failing };
    var invalid: zrx.Line(3) = .{};
    invalid.len = 4;
    try std.testing.expectError(error.InvalidLineLength, zrx.writeLine(&writer, invalid));
    try std.testing.expectError(error.WriteFailed, zrx.writeLine(&writer, try zrx.line(3, "abc")));
    try std.testing.expectError(error.WriteFailed, writer.write("text"));
}
