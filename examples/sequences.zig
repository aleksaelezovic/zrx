const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const keepIf = zrx.keepIf;
const filter = zrx.filter;
const each = zrx.each;
const collectInto = zrx.collectInto;
const collectAlloc = zrx.collectAlloc;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

fn double(value: u32) u32 {
    return value * 2;
}

pub fn main(init: std.process.Init) !void {
    const items = [_]u32{ 1, 2, 3, 4 };
    var storage: [4]u32 = undefined;
    const result = try pipe(&items, .{
        filter(isEven),
        each(double),
        collectInto(&storage),
    });
    if (!std.mem.eql(u32, result, &.{ 4, 8 })) return error.UnexpectedResult;

    const owned = try pipe(&items, .{
        filter(isEven),
        collectAlloc(init.gpa),
    });
    defer init.gpa.free(owned);
    if (!std.mem.eql(u32, owned, &.{ 2, 4 })) return error.UnexpectedResult;

    const kept: ?u32 = pipe(4, .{keepIf(isEven)});
    if (kept != 4) return error.UnexpectedResult;
}
