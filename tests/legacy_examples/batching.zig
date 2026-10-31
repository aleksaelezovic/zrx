//! Archived transport regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const batchThenWith = zrx.batchThenWith;
const run = zrx.run;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var service: MockLogService = .{};

    const logs: Stream(u32) = .fromProducer(1, produceLogs);
    const sendLogs = pipe(&logs, .{
        batchThenWith(100, &service, MockLogService.send),
    });
    try run(allocator, io, .{sendLogs});
    if (service.batches != 10 or service.logs != 1000 or service.next_id != 1001)
        return error.UnexpectedResult;
    std.debug.print("Sent {d} logs in {d} batches of 100\n", .{ service.logs, service.batches });
}

fn produceLogs(output: *Emitter(u32)) !void {
    for (1..1001) |id| try output.push(@intCast(id));
}

const MockLogService = struct {
    batches: usize = 0,
    logs: usize = 0,
    next_id: u32 = 1,

    fn send(self: *@This(), values: []const u32) !void {
        if (values.len != 100) return error.UnexpectedBatchSize;
        for (values) |id| {
            if (id != self.next_id) return error.OutOfOrder;
            self.next_id += 1;
        }
        self.logs += values.len;
        self.batches += 1;
        // The borrowed slice is not saved. A real service must finish using it
        // before returning, or explicitly retain an application-owned copy.
    }
};
