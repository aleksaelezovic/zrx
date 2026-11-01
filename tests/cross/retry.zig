//! Current retry API with runtime configuration and typed result-valued items.
const std = @import("std");
const zrx = @import("zrx");
const E = error{Failed};
const Budget = struct { retries: usize, delay: u64 };
fn step(item: u32) E!u64 {
    return if (item == 0) error.Failed else @as(u64, item) + 1;
}
fn double(item: u64) u64 {
    return item *% 2;
}
fn save(output: *u64, outcome: E!u64) void {
    output.* +%= outcome catch 0;
}
fn decide(budget: Budget, _: E, retries: usize) zrx.RetryDecision {
    return if (retries < budget.retries) .{ .retry_after_ms = budget.delay } else .stop;
}
export fn retry_fixed(a: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, attempts: usize, delay: u64, output: *u64) bool {
    const outcomes = zrx.retryPipe(zrx.fromSlice(input[0..len]), .{zrx.map(.{ step, double })}, .{ .max_attempts = attempts, .delay_ms = delay });
    zrx.run(.{ a.*, io.*, output }, .{zrx.pipe(outcomes, .{zrx.forEach(save)})}) catch return false;
    return true;
}
export fn retry_function(a: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, retries: usize, delay: u64, output: *u64) bool {
    const outcomes = zrx.retryPipe(zrx.fromSlice(input[0..len]), .{ zrx.map(step), zrx.map(double) }, decide);
    zrx.run(.{ a.*, io.*, output, Budget{ .retries = retries, .delay = delay } }, .{zrx.pipe(outcomes, .{zrx.forEach(save)})}) catch return false;
    return true;
}
