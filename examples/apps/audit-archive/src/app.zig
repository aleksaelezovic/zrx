const std = @import("std");
const zrx = @import("zrx");
const Io = std.Io;
const map = zrx.map;
const batch = zrx.batch;
const queue = zrx.queue;
const flatten = zrx.flatten;
const forEach = zrx.forEach;
const cli = @import("cli.zig");

pub const records = @import("records.zig");
pub const Input = struct { reader: *Io.Reader };
pub const Archive = struct { writer: *Io.Writer };
pub const batch_size = cli.batch_size;
pub const queue_depth = cli.queue_depth;
pub const output_buffer_bytes = cli.output_buffer_bytes;
pub const Line = zrx.Line(records.max_line);
pub const source = zrx.lines(Input, records.max_line);

pub fn redact(line: Line) !records.Record {
    return records.redact(line.text());
}

pub fn write(sink: Archive, record: records.Record) !void {
    try record.write(sink.writer);
}

pub fn archivePipe(comptime n: usize, slots: anytype) @TypeOf(zrx.pipe(.{
    map(redact),
    batch(n),
    queue(slots),
    flatten(),
    forEach(write),
})) {
    return zrx.pipe(.{
        map(redact),
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

fn run(io: Io, input: *Io.Reader, output: *Io.Writer, mode: cli.Mode) !void {
    switch (mode) {
        .queued => try archive(io, input, output),
        .sync => {
            const program = zrx.program(source, .{
                map(redact),
                forEach(write),
            });
            try program.run(.{ Input{ .reader = input }, Archive{ .writer = output } });
            try output.flush();
        },
    }
}

pub fn execute(io: Io, args: []const []const u8) !u8 {
    return cli.execute(io, args, run);
}

test {
    _ = records;
}
