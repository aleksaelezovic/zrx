const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
const collectThen = zrx.collectThen;
const collectThenWith = zrx.collectThenWith;
const maxItems = zrx.maxItems;
const run = zrx.run;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

fn double(value: u32) u32 {
    return value * 2;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const items = [_]u32{ 1, 2, 3, 4 };
    var saved: Saved = .{};
    const doubled = pipe(&items, .{
        filter(isEven),
        each(double),
        maxItems(2),
        collectThen(showDoubled),
    });

    const retained = pipe(&items, .{
        filter(isEven),
        collectThenWith(&saved, Saved.copy),
    });
    try run(allocator, io, .{ doubled, retained });
    if (!std.mem.eql(u32, saved.values[0..saved.len], &.{ 2, 4 })) return error.UnexpectedResult;

    const kept: ?u32 = pipe(4, .{keepIf(isEven)});
    if (kept != 4) return error.UnexpectedResult;
}

fn showDoubled(values: []const u32) !void {
    if (!std.mem.eql(u32, values, &.{ 4, 8 })) return error.UnexpectedResult;
    std.debug.print("Collected doubled values: {any}\n", .{values});
}

const Saved = struct {
    values: [4]u32 = undefined,
    len: usize = 0,

    fn copy(self: *@This(), values: []const u32) error{NoSpaceLeft}!void {
        if (values.len > self.values.len) return error.NoSpaceLeft;
        @memcpy(self.values[0..values.len], values);
        self.len = values.len;
    }
};
