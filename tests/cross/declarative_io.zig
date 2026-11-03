const std = @import("std");
const zrx = @import("zrx");
export fn declarative_file_copy(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u8, input_len: usize, output: [*]const u8, output_len: usize) bool {
    const source = zrx.fileLines(input[0..input_len], 64, 1);
    const flow = zrx.pipe(source, .{zrx.writeFileLines(output[0..output_len], .{ .exclusive = true })});
    zrx.run(.{ gpa.*, io.* }, .{flow}) catch return false;
    return true;
}

fn countArgs(output: *usize, args: *zrx.Arguments) void {
    output.* = args.values.len;
}
export fn declarative_arguments(gpa: *const std.mem.Allocator, io: *const std.Io, args: *const std.process.Args, count: *usize) bool {
    const flow = zrx.pipe(zrx.fromService(*zrx.Arguments), .{zrx.forEach(countArgs)});
    zrx.run(.{ gpa.*, io.*, zrx.arguments(args.*), count }, .{flow}) catch return false;
    return true;
}

fn write(writer: *zrx.Writer, value: zrx.Line(64)) !void {
    try zrx.writeLine(writer, value);
}
export fn declarative_writer(gpa: *const std.mem.Allocator, io: *const std.Io, output: [*]const u8, output_len: usize, input: [*]const u8, input_len: usize) bool {
    const value = zrx.Line(64).fromFormat("{s}", .{input[0..input_len]}) catch return false;
    const flow = zrx.pipe(zrx.fromValue(value), .{zrx.forEach(write)});
    zrx.run(.{ gpa.*, io.*, zrx.writer(.{ .file = .{ .path = output[0..output_len], .options = .{ .exclusive = true } } }) }, .{flow}) catch return false;
    return true;
}

const ReaderRole = struct { reader: *std.Io.Reader };
fn countLine(count: *usize, _: zrx.Line(64)) void {
    count.* += 1;
}
fn expandReader(role: ReaderRole, _: u8) @TypeOf(zrx.readerLines(64, @as(*std.Io.Reader, undefined))) {
    return zrx.readerLines(64, role.reader);
}
export fn declarative_reader(gpa: *const std.mem.Allocator, io: *const std.Io, input: *std.Io.Reader, count: *usize) bool {
    const flow = zrx.pipe(zrx.fromValue(@as(u8, 0)), .{ zrx.flatMap(expandReader), zrx.forEach(countLine) });
    zrx.run(.{ gpa.*, io.*, ReaderRole{ .reader = input }, count }, .{flow}) catch return false;
    return true;
}

fn expandManagedReader(reader: *zrx.Reader) @TypeOf(zrx.readerLines(64, @as(*zrx.Reader, undefined))) {
    return zrx.readerLines(64, reader);
}
export fn declarative_managed_reader(gpa: *const std.mem.Allocator, io: *const std.Io, path: [*]const u8, path_len: usize, count: *usize) bool {
    const flow = zrx.pipe(zrx.fromService(*zrx.Reader), .{ zrx.flatMap(expandManagedReader), zrx.forEach(countLine) });
    zrx.run(.{ gpa.*, io.*, zrx.reader(.{ .file = path[0..path_len] }), count }, .{flow}) catch return false;
    return true;
}

export fn declarative_byte_copy(gpa: *const std.mem.Allocator, io: *const std.Io, input: *std.Io.Reader, output: *std.Io.Writer) bool {
    const flow = zrx.pipe(zrx.readChunks(1024, input), .{zrx.writeTo(output)});
    zrx.run(.{ gpa.*, io.* }, .{flow}) catch return false;
    return true;
}

const FilePaths = struct { input: []const u8, output: []const u8 };
const ConfiguredInput = struct { reader: *zrx.Reader };
fn inputConfig(paths: FilePaths) zrx.Reader.Config {
    return .{ .file = paths.input };
}
fn outputConfig(paths: FilePaths) zrx.Writer.Config {
    return .{ .file = .{ .path = paths.output, .options = .{ .exclusive = true } } };
}
fn configuredChunks(input: ConfiguredInput) @TypeOf(zrx.readChunks(1024, @as(*zrx.Reader, undefined))) {
    return zrx.readChunks(1024, input.reader);
}
export fn declarative_configured_copy(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u8, input_len: usize, output: [*]const u8, output_len: usize) bool {
    const flow = zrx.pipe(zrx.fromService(ConfiguredInput), .{
        zrx.flatMap(configuredChunks), zrx.writeTo(*zrx.Writer),
    });
    zrx.run(.{
        gpa.*,
        io.*,
        FilePaths{ .input = input[0..input_len], .output = output[0..output_len] },
        zrx.deriveResource(ConfiguredInput, zrx.reader(inputConfig)),
        zrx.writer(outputConfig),
    }, .{flow}) catch return false;
    return true;
}
