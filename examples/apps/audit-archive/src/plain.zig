//! Standalone std-only baseline. A borrowed input line is parsed before the
//! reader advances. Only owned records leave the producer.
const std = @import("std");
const cli = @import("cli.zig");
const records = @import("records.zig");
const Io = std.Io;

const Batch = struct {
    items: [cli.batch_size]records.Record,
    len: usize,
};
const Queue = Io.Queue(Batch);

fn next(input: *Io.Reader) !?records.Record {
    const line = input.peekDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => input.buffered(),
        else => return err,
    };
    if (line.len == 0) return null;
    const text = if (line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
    if (text.len > records.max_line) return error.StreamTooLong;
    const record = try records.redact(text);
    input.toss(line.len);
    return record;
}

fn produce(io: Io, input: *Io.Reader, queue: *Queue) !void {
    var pending: [cli.batch_size]records.Record = undefined;
    var len: usize = 0;
    while (try next(input)) |record| {
        pending[len] = record;
        len += 1;
        if (len == pending.len) {
            try queue.putOne(io, .{ .items = pending, .len = len });
            len = 0;
        }
    }
    if (len != 0) try queue.putOne(io, .{ .items = pending, .len = len });
}

fn consume(io: Io, writer: *Io.Writer, queue: *Queue) !void {
    while (true) {
        const group = queue.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        for (group.items[0..group.len]) |record| try record.write(writer);
    }
}

pub fn archive(io: Io, input: *Io.Reader, writer: *Io.Writer, mode: cli.Mode) !void {
    switch (mode) {
        .sync => while (try next(input)) |record| try record.write(writer),
        .queued => {
            const Result = union(enum) {
                producer: @typeInfo(@TypeOf(produce)).@"fn".return_type.?,
                consumer: @typeInfo(@TypeOf(consume)).@"fn".return_type.?,
            };
            var results: [2]Result = undefined;
            var tasks = Io.Select(Result).init(io, &results);
            var slots: [cli.queue_depth]Batch = undefined;
            var queue: Queue = .init(&slots);
            defer {
                queue.close(io);
                tasks.cancelDiscard();
            }
            try tasks.concurrent(.producer, produce, .{ io, input, &queue });
            try tasks.concurrent(.consumer, consume, .{ io, writer, &queue });

            // A successful producer ends the queue after its final put. A
            // failure on either side closes the queue and cancels its peer.
            for (0..2) |_| {
                switch (try tasks.await()) {
                    .producer => |result| {
                        try result;
                        queue.close(io);
                    },
                    .consumer => |result| try result,
                }
            }
        },
    }
    try writer.flush();
}

pub fn execute(io: Io, args: []const []const u8) !u8 {
    return cli.execute(io, args, archive);
}

test "a queued consumer failure fails the run" {
    var reader: Io.Reader = .fixed(
        \\{"id":1,"ts_ms":2,"action":"read","resource":"r","actor":"a"}
    );
    var writer: Io.Writer = .fixed(&.{});
    try std.testing.expectError(error.WriteFailed, archive(std.testing.io, &reader, &writer, .queued));
}
