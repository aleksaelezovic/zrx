//! Current public scan API instantiated with runtime inputs on every catalog
//! target. Object coverage, not foreign execution or body-equality evidence.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const run = zrx.run;
const fromSlice = zrx.fromSlice;
const scan = zrx.scan;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const forEach = zrx.forEach;
const Scale = struct { factor: u32 };

fn add(scale: Scale, state: u64, item: u32) u64 {
    return state +% (@as(u64, item) *% scale.factor);
}
fn save(output: *u64, value: u64) void {
    output.* = value;
}
fn saveSample(output: *u64, pair: struct { u32, u64 }) void {
    output.* = pair[1];
}
export fn declarative_scan_finite(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, factor: u32, output: *u64) bool {
    const flow = pipe(fromSlice(input[0..len]), .{ scan(@as(u64, 0), add), forEach(save) });
    run(.{ gpa.*, io.*, Scale{ .factor = factor }, output }, .{flow}) catch return false;
    return true;
}
export fn declarative_scan_state(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, factor: u32, output: *u64) bool {
    const updates = pipe(fromSlice(input[0..len]), .{scan(@as(u64, 0), add)});
    const state = pipe(&updates, .{hold(@as(u64, 0))});
    const flow = pipe(values(&state), .{forEach(save)});
    run(.{ gpa.*, io.*, Scale{ .factor = factor }, output }, .{flow}) catch return false;
    return true;
}
export fn declarative_scan_sampling(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, factor: u32, events: [*]const u32, count: usize, output: *u64) bool {
    const updates = pipe(fromSlice(input[0..len]), .{scan(@as(u64, 0), add)});
    const state = pipe(&updates, .{hold(@as(u64, 0))});
    const flow = pipe(fromSlice(events[0..count]), .{ withLatestFrom(&state), forEach(saveSample) });
    run(.{ gpa.*, io.*, Scale{ .factor = factor }, output }, .{flow}) catch return false;
    return true;
}
