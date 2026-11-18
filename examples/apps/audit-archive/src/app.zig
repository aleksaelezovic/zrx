const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const map = zrx.map;
const batch = zrx.batch;
const queue = zrx.queue;
const flatten = zrx.flatten;
const forEach = zrx.forEach;

pub const records = @import("records.zig");
pub const Input = struct { reader: *Io.Reader };
pub const Archive = struct { writer: *Io.Writer };
pub const batch_size = 32;
pub const queue_depth = 4;
pub const output_buffer_bytes = 16 * 1024;
pub const source = zrx.lines(Input, records.max_line);

pub fn write(sink: Archive, record: records.Record) !void {
    try record.write(sink.writer);
}

pub fn archivePipe(comptime n: usize, slots: anytype) @TypeOf(zrx.pipe(.{
    map(records.redact),
    batch(n),
    queue(slots),
    flatten(),
    forEach(write),
})) {
    return zrx.pipe(.{
        map(records.redact),
        batch(n),
        queue(slots),
        flatten(),
        forEach(write),
    });
}

pub fn archive(io: Io, input: *Io.Reader, output: *Io.Writer) !void {
    var slots: [queue_depth]zrx.Batch(records.Record, batch_size) = undefined;
    const program = zrx.program(source, archivePipe(batch_size, &slots));
    try program.run(.{ io, Input{ .reader = input }, Archive{ .writer = output } });
    try output.flush();
}

const usage = "usage: audit-archive INPUT|- OUTPUT\n";

pub fn execute(io: Io, args: []const []const u8) !u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        var buffer: [128]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(io, &buffer);
        try writer.interface.writeAll(usage);
        try writer.interface.flush();
        return 0;
    }
    if (args.len != 2) return error.InvalidArguments;
    const stdin = std.mem.eql(u8, args[0], "-");
    const dir = Io.Dir.cwd();
    const input_file = if (stdin) Io.File.stdin() else try dir.openFile(io, args[0], .{});
    defer if (!stdin) input_file.close(io);
    var output_file = try dir.createFileAtomic(io, args[1], .{});
    defer output_file.deinit(io);

    var input_buffer: [records.max_line + 1]u8 = undefined;
    var output_buffer: [output_buffer_bytes]u8 = undefined;
    var input = input_file.readerStreaming(io, &input_buffer);
    var output = output_file.file.writerStreaming(io, &output_buffer);
    try archive(io, &input.interface, &output.interface);
    try output_file.link(io);
    return 0;
}

test {
    _ = records;
}
