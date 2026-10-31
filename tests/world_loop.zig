//! Runtime-input fixture for scoped LLVM inspection of current public finite
//! execution. Not a new target catalog or equality check.
const std = @import("std");
const world = @import("zrx");
const pipe = world.pipe;
const fromSlice = world.fromSlice;
const each = world.each;
const forEach = world.forEach;
const run = world.run;

fn expand(value: u32) u64 {
    return @as(u64, value) * 3 + 1;
}

fn add(total: *u64, value: u64) void {
    total.* +%= value;
}

pub export fn world_finite_loop(resource_io: *const std.Io, input: [*]const u32, len: usize, total: *u64) bool {
    const flow = pipe(fromSlice(input[0..len]), .{ each(expand), forEach(add) });
    run(.{ std.heap.page_allocator, resource_io.*, total }, .{flow}) catch return false;
    return true;
}

// Same work AND cancellation checkpoints as the declaration-only execution.
// This is contextual native fixture evidence, not a catalog equality assertion.
pub export fn direct_finite_loop(resource_io: *const std.Io, input: [*]const u32, len: usize, total: *u64) bool {
    const io = resource_io.*;
    io.checkCancel() catch return false;
    io.checkCancel() catch return false;
    var index: usize = 0;
    while (true) {
        io.checkCancel() catch return false;
        if (index == len) return true;
        total.* +%= @as(u64, input[index]) * 3 + 1;
        index += 1;
    }
}
