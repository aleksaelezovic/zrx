const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const each = zrx.each;
const forEach = zrx.forEach;
const fromSlice = zrx.fromSlice;
const run = zrx.run;

fn positive(value: i32) bool {
    return value > 0;
}
fn magnitude(value: i32) u32 {
    return @abs(value);
}
fn add(sum: *u64, value: u32) void {
    sum.* += value;
}
const Counts = struct { values: [2]u64 = .{ 0, 0 } };
fn countPositive(sum: *Counts, _: i32) void {
    sum.values[0] += 1;
}
fn countNonpositive(sum: *Counts, _: i32) void {
    sum.values[1] += 1;
}

export fn branch_values(a: *const std.mem.Allocator, io: *const std.Io, data: [*]const i32, len: usize) u64 {
    var sum: u64 = 0;
    const flow = pipe(fromSlice(data[0..len]), .{
        branch(.{
            when(positive, each(magnitude)),
            otherwise(.{each(magnitude)}),
        }),
        forEach(add),
    });
    run(.{ a.*, io.*, &sum }, .{flow}) catch return 0;
    return sum;
}

export fn branch_terminals(a: *const std.mem.Allocator, io: *const std.Io, data: [*]const i32, len: usize) u64 {
    var sums: Counts = .{};
    const flow = pipe(fromSlice(data[0..len]), .{branch(.{
        when(positive, forEach(countPositive)),
        otherwise(.{forEach(countNonpositive)}),
    })});
    run(.{ a.*, io.*, &sums }, .{flow}) catch return 0;
    return sums.values[0] + sums.values[1];
}
