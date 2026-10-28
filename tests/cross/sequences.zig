const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
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
