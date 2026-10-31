//! Exclusive cases whose pipelines all terminate: branch is itself a terminal.
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

pub const Counts = struct { negative: usize = 0, nonnegative: usize = 0 };
const Negative = struct { value: *usize };
const Nonnegative = struct { value: *usize };

pub fn main(init: std.process.Init) !void {
    const values = [_]i32{ -2, -1, 0, 1, 2 };
    const counts = try execute(init.gpa, init.io, &values);
    var buffer: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try writer.interface.print("negative={d} nonnegative={d}\n", .{ counts.negative, counts.nonnegative });
    try writer.interface.flush();
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, values: []const i32) !Counts {
    var counts: Counts = .{};
    const effect = pipe(fromSlice(values), .{
        branch(.{
            when(isNegative, forEach(countSigned)),
            otherwise(.{ each(magnitude), forEach(countUnsigned) }),
        }),
    });
    try run(.{ allocator, io, Negative{ .value = &counts.negative }, Nonnegative{ .value = &counts.nonnegative } }, .{effect});
    return counts;
}

fn isNegative(value: i32) bool {
    return value < 0;
}
fn magnitude(value: i32) u32 {
    return @abs(value);
}
fn countSigned(count: Negative, _: i32) void {
    count.value.* += 1;
}
fn countUnsigned(count: Nonnegative, _: u32) void {
    count.value.* += 1;
}
