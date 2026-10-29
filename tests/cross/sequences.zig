const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
const fold = zrx.fold;
const tryFold = zrx.tryFold;
const collectInto = zrx.collectInto;
const collectAlloc = zrx.collectAlloc;

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

export fn buffer_coverage(source: [*]const u32, len: usize, buffer: [*]u32, capacity: usize) usize {
    const result = pipe(source[0..len], .{
        filter(even),
        each(twice),
        collectInto(buffer[0..capacity]),
    }) catch return std.math.maxInt(usize);
    return result.len;
}

export fn allocation_coverage(allocator: *const std.mem.Allocator, source: [*]const u32, len: usize) usize {
    const owned = pipe(source[0..len], .{
        filter(even),
        each(twice),
        collectAlloc(allocator.*),
    }) catch return std.math.maxInt(usize);
    defer allocator.free(owned);
    return owned.len;
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
