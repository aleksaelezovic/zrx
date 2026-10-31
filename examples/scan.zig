//! A transfer monitor: accumulated chunks drive a dashboard, while independent
//! requests sample committed progress. Request/chunk interleaving is unspecified.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const scan = zrx.scan;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

pub const Chunk = struct { bytes: u32 };
pub const Totals = struct { chunks: u64 = 0, bytes: u64 = 0 };
const Report = @Tuple(&.{ u32, Totals });

fn addChunk(previous: Totals, chunk: Chunk) Totals {
    return .{
        .chunks = previous.chunks +| 1,
        .bytes = previous.bytes +| chunk.bytes,
    };
}

fn writeTotals(writer: *std.Io.Writer, total: Totals) !void {
    try writer.print("{d} chunks, {d} bytes\n", .{ total.chunks, total.bytes });
}

fn writeReport(writer: *std.Io.Writer, report: Report) !void {
    try writer.print("request {d}: {d} bytes\n", .{ report[0], report[1].bytes });
}

/// The callers own two distinct writers and source capabilities through run.
/// Only the held cache defines sampled progress; upstream admission is not commit.
pub fn monitor(
    allocator: std.mem.Allocator,
    io: std.Io,
    chunks: *const Stream(Chunk),
    requests: *const Stream(u32),
    dashboard: *std.Io.Writer,
    replies: *std.Io.Writer,
) !void {
    const seed: Totals = .{};
    const totals = pipe(chunks, .{scan(seed, addChunk)});
    const current = pipe(&totals, .{hold(seed)});
    const displayFlow = pipe(values(&current), .{
        forEachWith(dashboard, writeTotals),
    });
    const replyFlow = pipe(requests, .{
        withLatestFrom(&current),
        forEachWith(replies, writeReport),
    });
    try run(allocator, io, .{ displayFlow, replyFlow });
}

pub fn main(init: std.process.Init) !void {
    var progress_buffer: [256]u8 = undefined;
    var report_buffer: [256]u8 = undefined;
    var dashboard: std.Io.Writer = .fixed(&progress_buffer);
    var replies: std.Io.Writer = .fixed(&report_buffer);
    const chunks = Stream(Chunk).fromProducer(1, produceChunks);
    const requests = Stream(u32).fromProducer(1, produceRequests);
    try monitor(init.gpa, init.io, &chunks, &requests, &dashboard, &replies);
    std.debug.print("Transfer progress:\n{s}Sampled reports:\n{s}", .{ dashboard.buffered(), replies.buffered() });
}

fn produceChunks(output: *Emitter(Chunk)) !void {
    for ([_]u32{ 3, 5, 0 }) |bytes| try output.push(.{ .bytes = bytes });
}

fn produceRequests(output: *Emitter(u32)) !void {
    try output.push(1);
    try output.push(2);
}
