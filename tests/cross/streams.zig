const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromIterator = zrx.fromIterator;
const readFrom = zrx.readFrom;
const each = zrx.each;
const filter = zrx.filter;
const collectThenWith = zrx.collectThenWith;
const maxItems = zrx.maxItems;
const forEachWith = zrx.forEachWith;
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const run = zrx.run;

const Input = struct {
    remaining: u32,

    pub fn next(self: *@This()) error{Rejected}!?u32 {
        if (self.remaining == 0) return null;
        if (self.remaining > 4) return error.Rejected;
        const value = self.remaining;
        self.remaining -= 1;
        return value;
    }
};

fn double(value: u32) u64 {
    return @as(u64, value) * 2;
}

fn even(value: u32) bool {
    return value % 2 == 0;
}

fn record(total: *u64, value: u64) error{Overflow}!void {
    const result = @addWithOverflow(total.*, value);
    if (result[1] != 0) return error.Overflow;
    total.* = result[0];
}

export fn iterator_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, value: u32, destination: *u64) bool {
    var input: Input = .{ .remaining = value };
    const flow = pipe(fromIterator(&input), .{
        filter(even),
        each(double),
        forEachWith(destination, record),
    });
    run(allocator.*, io.*, .{flow}) catch return false;
    return true;
}

const Saved = struct {
    output: *[4]u64,
    len: usize = 0,
    fn copy(self: *@This(), values: []const u64) !void {
        if (values.len > self.output.len) return error.NoSpaceLeft;
        @memcpy(self.output[0..values.len], values);
        self.len = values.len;
    }
};

export fn queue_coverage(allocator: *const std.mem.Allocator, queue: *std.Io.Queue(u32), io: *const std.Io, output: *[4]u64) usize {
    var saved: Saved = .{ .output = output };
    const flow = pipe(readFrom(io.*, queue), .{
        filter(even),
        each(double),
        maxItems(4),
        collectThenWith(&saved, Saved.copy),
    });
    run(allocator.*, io.*, .{flow}) catch return 0;
    return saved.len;
}

fn produce(output: *Emitter(u32)) error{ Closed, Canceled }!void {
    try output.push(3);
}

export fn producer_stream_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, output: *[1]u64) bool {
    output.* = .{0};
    const input = Stream(u32).fromProducer(1, produce);
    run(allocator.*, io.*, .{
        pipe(&input, .{ each(double), forEachWith(&output[0], record) }),
    }) catch return false;
    return true;
}

fn produceValue(value: *const u32, output: *Emitter(u32)) error{ Closed, Canceled }!void {
    try output.push(value.*);
}

export fn capable_producer_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, value: u32, output: *[1]u64) bool {
    output.* = .{0};
    const input = Stream(u32).fromProducerWith(1, produceValue, &value);
    run(allocator.*, io.*, .{
        pipe(&input, .{ each(double), forEachWith(&output[0], record) }),
    }) catch return false;
    return true;
}

export fn declared_flows_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, value: u32, output: *[2]u64) bool {
    output.* = .{ 0, 0 };
    const input = Stream(u32).fromProducerWith(1, produceValue, &value);
    const doubled = pipe(&input, .{each(double)});
    run(allocator.*, io.*, .{
        pipe(&doubled, .{forEachWith(&output[0], record)}),
        pipe(&doubled, .{forEachWith(&output[1], record)}),
    }) catch return false;
    return true;
}
