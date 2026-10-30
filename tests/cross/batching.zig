const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const merge = zrx.merge;
const batchThen = zrx.batchThen;
const batchThenWith = zrx.batchThenWith;
const run = zrx.run;

fn count(output: *[2]usize, values: []const u32) void {
    output[0] += 1;
    output[1] += values.len;
}

export fn finite_batch_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize, size: usize, output: *[2]usize) bool {
    output.* = .{ 0, 0 };
    const flow = pipe(source[0..len], .{batchThenWith(size, output, count)});
    run(allocator.*, io.*, .{flow}) catch return false;
    return true;
}

fn produce(value: *const u32, output: *Emitter(u32)) !void {
    try output.push(value.*);
}

fn sum(output: *[2]u64, values: []const u32) void {
    output[0] +%= 1;
    for (values) |value| output[1] +%= value;
}

export fn declared_batch_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, value: u32, size: usize, output: *[2]u64) bool {
    output.* = .{ 0, 0 };
    const source = Stream(u32).fromProducerWith(1, produce, &value);
    const combined = merge(.{ &source, &source });
    const flow = pipe(&combined, .{batchThenWith(size, output, sum)});
    run(allocator.*, io.*, .{flow}) catch return false;
    return true;
}

fn inspect(values: []const u32) !void {
    if (values.len == 0) return error.UnexpectedEmptyBatch;
}

export fn unary_batch_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize, size: usize) bool {
    const flow = pipe(source[0..len], .{batchThen(size, inspect)});
    run(allocator.*, io.*, .{flow}) catch return false;
    return true;
}
