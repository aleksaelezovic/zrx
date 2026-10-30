const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

fn double(value: i32) i64 {
    return @as(i64, value) * 2;
}
fn record(total: *i64, value: i64) void {
    total.* +%= value;
}
const Pair = @Tuple(&.{ u32, i64 });
fn sample(total: *i64, item: Pair) void {
    total.* +%= item[1];
}

export fn signal_coverage(allocator: *const std.mem.Allocator, io: *const std.Io, source: [*]const i32, len: usize, initial: i32, events: [*]const u32, event_count: usize, output: *[2]i64) bool {
    output.* = .{ 0, 0 };
    const current = pipe(source[0..len], .{hold(initial)});
    const doubled = tryPipe(&current, .{map(double)}) catch return false;
    run(allocator.*, io.*, .{
        pipe(values(&doubled), .{forEachWith(&output[0], record)}),
        pipe(events[0..event_count], .{ withLatestFrom(&doubled), forEachWith(&output[1], sample) }),
    }) catch return false;
    return true;
}
