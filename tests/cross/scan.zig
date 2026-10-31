const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const scan = zrx.scan;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

fn add(total: u64, value: u32) u64 {
    return total +% value;
}
fn record(destination: *u64, value: u64) void {
    destination.* +%= value;
}
fn report(destination: *u64, pair: @Tuple(&.{ u8, u64 })) void {
    destination.* +%= pair[1];
}

export fn scan_coverage(
    allocator: *const std.mem.Allocator,
    io: *const std.Io,
    input: [*]const u32,
    len: usize,
    seed: u64,
    events: [*]const u8,
    event_count: usize,
    output: *[2]u64,
) bool {
    output.* = .{ 0, 0 };
    const totals = pipe(input[0..len], .{scan(seed, add)});
    const current = pipe(&totals, .{hold(seed)});
    run(allocator.*, io.*, .{
        pipe(values(&current), .{forEachWith(&output[0], record)}),
        pipe(events[0..event_count], .{ withLatestFrom(&current), forEachWith(&output[1], report) }),
    }) catch return false;
    return true;
}
