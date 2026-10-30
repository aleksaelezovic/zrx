const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const merge = zrx.merge;
const takeLast = zrx.takeLast;
const maxItems = zrx.maxItems;
const collectThenWith = zrx.collectThenWith;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const Destination = struct {
    buffer: []u32,
    len: usize = 0,
    fn copy(self: *@This(), values: []const u32) !void {
        if (values.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[0..values.len], values);
        self.len = values.len;
    }
};

export fn finite_merge_coverage(
    allocator: *const std.mem.Allocator,
    io: *const std.Io,
    a: [*]const u32,
    a_len: usize,
    b: [*]const u32,
    b_len: usize,
    limit: usize,
    output: [*]u32,
    capacity: usize,
) usize {
    const combined = merge(.{ a[0..a_len], b[0..b_len] });
    var destination: Destination = .{ .buffer = output[0..capacity] };
    const flow = pipe(&combined, .{
        takeLast(limit),
        maxItems(capacity),
        collectThenWith(&destination, Destination.copy),
    });
    run(allocator.*, io.*, .{flow}) catch return std.math.maxInt(usize);
    return destination.len;
}

fn produce(value: *const u32, output: *Emitter(u32)) !void {
    try output.push(value.*);
}

fn twice(value: u32) u32 {
    return value *% 2;
}

fn add(total: *u64, value: u32) void {
    total.* +%= value;
}

export fn shared_merge_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, value: u32, output: *u64) bool {
    output.* = 0;
    const source = Stream(u32).fromProducerWith(1, produce, &value);
    const doubled = pipe(&source, .{each(twice)});
    const combined = merge(.{ &source, &doubled });
    run(allocator.*, io.*, .{pipe(&combined, .{forEachWith(output, add)})}) catch return false;
    return true;
}
