const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const take = zrx.take;
const each = zrx.each;
const fold = zrx.fold;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

fn sum(total: u64, value: u32) u64 {
    return total +% value;
}

export fn finite_prefix(source: [*]const u32, len: usize, limit: usize) u64 {
    return pipe(source[0..len], .{ take(limit), fold(@as(u64, 0), sum) });
}

const Total = struct {
    value: u64 = 0,
    fn add(self: *@This(), value: u64) void {
        self.value +%= value;
    }
};

fn widen(value: u32) u64 {
    return value;
}

export fn shared_prefix(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const u32, len: usize, limit: usize) u64 {
    const input = pipe(source[0..len], .{each(widen)});
    var short: Total = .{};
    var full: Total = .{};
    run(allocator.*, io.*, .{
        pipe(&input, .{ take(limit), forEachWith(&short, Total.add) }),
        pipe(&input, .{forEachWith(&full, Total.add)}),
    }) catch return 0xffffffffffffffff;
    return short.value +% full.value;
}
