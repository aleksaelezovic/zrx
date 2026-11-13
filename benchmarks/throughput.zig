//! Throughput of a pipeline against the equivalent hand-written loop. Run
//! with `zig build benchmark`; numbers depend on
//! the machine and are reported, never asserted. The zero-overhead claim is
//! checked structurally by `zig build zero-overhead`.
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const subscribe = zrx.subscribe;

const Scale = struct { by: u32 };
const Total = struct { out: *u64 };

fn scale(factor: Scale, value: u32) u32 {
    return value *% factor.by;
}
fn isOdd(value: u32) bool {
    return value % 2 == 1;
}
fn add(sum: u64, value: u32) u64 {
    return sum +% value;
}
fn store(total: Total, value: u64) void {
    total.out.* = value;
}

const direct = pipe(.{ map(scale), filter(isOdd), fold(@as(u64, 0), add), subscribe(store) });

fn byHand(items: []const u32, by: u32) u64 {
    var sum: u64 = 0;
    for (items) |value| {
        const scaled = value *% by;
        if (scaled % 2 == 1) sum +%= scaled;
    }
    return sum;
}

fn byPipe(comptime work: anytype, items: []const u32, by: u32) !u64 {
    var total: u64 = 0;
    try program(fromSlice(items), work).run(.{ Scale{ .by = by }, Total{ .out = &total } });
    return total;
}

const trials = 7;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const count: usize = 1 << 22;
    const items = try init.gpa.alloc(u32, count);
    defer init.gpa.free(items);
    io.random(std.mem.sliceAsBytes(items));
    var by: u32 = 3;
    std.mem.doNotOptimizeAway(&by);

    const expected = byHand(items, by);
    var best: [2]u64 = @splat(std.math.maxInt(u64));
    for (0..trials) |_| {
        inline for (0..2) |variant| {
            const start = std.Io.Timestamp.now(io, .awake);
            const result = switch (variant) {
                0 => byHand(items, by),
                else => try byPipe(direct, items, by),
            };
            const elapsed: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
            if (result != expected) return error.WrongResult;
            best[variant] = @min(best[variant], elapsed);
        }
    }

    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &out.interface;
    try w.print("{d} items, best of {d} runs\n", .{ count, trials });
    inline for (.{ "hand-written loop", "zrx pipeline" }, 0..) |label, variant| {
        const per_item = @as(f64, @floatFromInt(best[variant])) / @as(f64, @floatFromInt(count));
        try w.print("  {s:<28} {d:>8.3} ns/item\n", .{ label, per_item });
    }
    try w.flush();
}
