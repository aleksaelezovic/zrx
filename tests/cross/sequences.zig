const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
const fold = zrx.fold;
const tryFold = zrx.tryFold;
const collectThenWith = zrx.collectThenWith;
const maxItems = zrx.maxItems;
const takeLast = zrx.takeLast;
const run = zrx.run;

fn even(value: u32) bool {
    return value % 2 == 0;
}

fn twice(value: u32) u32 {
    return value *% 2;
}

export fn scalar_coverage(value: u32) u32 {
    return pipe(value, .{keepIf(even)}) orelse 0;
}

export fn view_coverage(source: [*]const u32, len: usize) u32 {
    const view = pipe(source[0..len], .{ filter(even), each(twice) });
    var iterator = view.iterator();
    var total: u32 = 0;
    while (iterator.next()) |value| total +%= value;
    return total;
}

const Destination = struct {
    buffer: []u32,
    len: usize = 0,

    fn copy(self: *@This(), values: []const u32) !void {
        if (values.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[0..values.len], values);
        self.len = values.len;
    }
};

export fn buffer_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize, buffer: [*]u32, capacity: usize) usize {
    var destination: Destination = .{ .buffer = buffer[0..capacity] };
    const flow = pipe(source[0..len], .{
        filter(even),
        each(twice),
        maxItems(capacity),
        collectThenWith(&destination, Destination.copy),
    });
    run(allocator.*, io.*, .{flow}) catch return std.math.maxInt(usize);
    return destination.len;
}

fn storeLength(destination: *usize, values: []const u32) void {
    destination.* = values.len;
}

export fn allocation_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize) usize {
    var length: usize = 0;
    const flow = pipe(source[0..len], .{
        filter(even),
        each(twice),
        collectThenWith(&length, storeLength),
    });
    run(allocator.*, io.*, .{flow}) catch return std.math.maxInt(usize);
    return length;
}

fn accumulate(total: u64, value: u32) u64 {
    return total +% value;
}

export fn fold_coverage(source: [*]const u32, len: usize, initial: u64) u64 {
    return pipe(source[0..len], .{ filter(even), each(twice), fold(initial, accumulate) });
}

const Stats = struct {
    total: u64,
    count: usize = 0,

    fn update(self: @This(), value: u32) @This() {
        return .{ .total = self.total +% value, .count = self.count + 1 };
    }
};

export fn fold_struct_coverage(source: [*]const u32, len: usize, initial: u64, count: *usize) u64 {
    const result = pipe(source[0..len], .{fold(Stats{ .total = initial }, Stats.update)});
    count.* = result.count;
    return result.total;
}

const Element = error{Zero}!u32;

fn asElement(value: u32) Element {
    return if (value == 0) error.Zero else value;
}

fn countErrors(total: usize, value: Element) usize {
    _ = value catch return total + 1;
    return total;
}

export fn fold_error_data_coverage(source: [*]const u32, len: usize) usize {
    return pipe(source[0..len], .{ each(asElement), fold(0, countErrors) });
}

fn checkedAccumulate(total: u64, value: u32) error{Zero}!u64 {
    if (value == 0) return error.Zero;
    return accumulate(total, value);
}

export fn try_fold_coverage(source: [*]const u32, len: usize, initial: u64, output: *u64) bool {
    output.* = pipe(source[0..len], .{tryFold(initial, checkedAccumulate)}) catch return false;
    return true;
}

export fn retention_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize, limit: usize, buffer: [*]u32, capacity: usize) usize {
    var destination: Destination = .{ .buffer = buffer[0..capacity] };
    const flow = pipe(source[0..len], .{
        takeLast(limit),
        each(twice),
        maxItems(capacity),
        collectThenWith(&destination, Destination.copy),
    });
    run(allocator.*, io.*, .{flow}) catch return std.math.maxInt(usize);
    return destination.len;
}
