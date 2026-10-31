//! Archived transport regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const takeLast = zrx.takeLast;
const collectThen = zrx.collectThen;
const run = zrx.run;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const logs: Stream(u32) = .fromProducer(1, produceLogs);
    const showRecentLogs = pipe(&logs, .{
        takeLast(100),
        collectThen(showTail),
    });
    try run(allocator, io, .{showRecentLogs});
}

fn produceLogs(output: *Emitter(u32)) !void {
    for (1..1001) |number| try output.push(@intCast(number));
}

fn showTail(logs: []const u32) !void {
    if (logs.len != 100 or logs[0] != 901 or logs[logs.len - 1] != 1000)
        return error.UnexpectedResult;
    std.debug.print("Retained {d} logs: {d}..{d}\n", .{ logs.len, logs[0], logs[logs.len - 1] });
}
