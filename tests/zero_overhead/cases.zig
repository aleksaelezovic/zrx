//! Zero-overhead fixtures.
//!
//! Every case is written twice: as a zrx program and as the loop one would
//! write by hand. The build compiles this file once per variant in ReleaseFast
//! and `tools/same_code.zig` compares the optimized code of each exported
//! function: `same_*` must be the same instructions, `lean_*` must be free of
//! calls and extra memory traffic. `behavior.zig` runs both variants of every
//! case and requires equal results.
const std = @import("std");
const zrx = @import("zrx");

const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const take = zrx.take;
const flatten = zrx.flatten;
const provide = zrx.provide;
const subscribe = zrx.subscribe;

/// Which variant the exported functions are compiled as.
const exported_with_zrx = @import("variant").with_zrx;

const Scale = struct { by: u32 };
const Result = struct { out: *u64 };

fn scale(factor: Scale, value: u32) u32 {
    return value *% factor.by;
}
fn isLarge(value: u32) bool {
    return value >= 6;
}
fn isEven(value: u32) bool {
    return value % 2 == 0;
}
fn add(sum: u64, value: u32) u64 {
    return sum +% value;
}
fn store(result: Result, value: u64) void {
    result.out.* = value;
}

/// These programs cannot fail; say so, so that no error path is compiled in.
fn run(runnable: anytype, deps: anytype) void {
    runnable.run(deps) catch unreachable;
}

// --- injected map, filter, fold ---------------------------------------------

pub fn sumScaled(comptime with_zrx: bool, items: []const u32, by: u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(scale), filter(isLarge), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(items), total), .{ Scale{ .by = by }, Result{ .out = out } });
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            const scaled = value *% by;
            if (scaled >= 6) sum +%= scaled;
        }
        out.* = sum;
    }
}

export fn same_sum_scaled(ptr: [*]const u32, len: usize, by: u32, out: *u64) void {
    sumScaled(exported_with_zrx, ptr[0..len], by, out);
}

// --- nested pipes and provide -------------------------------------------------

pub fn nestedProvide(comptime with_zrx: bool, items: []const u32, by: u32, out: *u64) void {
    if (with_zrx) {
        const scaled = pipe(.{ provide(Scale{ .by = by }), map(scale) });
        const even = pipe(.{ scaled, pipe(.{filter(isEven)}) });
        const total = pipe(.{ even, pipe(.{ fold(@as(u64, 0), add), provide(Result{ .out = out }), subscribe(store) }) });
        run(program(fromSlice(items), total), .{});
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            const scaled = value *% by;
            if (scaled % 2 == 0) sum +%= scaled;
        }
        out.* = sum;
    }
}

export fn same_nested_provide(ptr: [*]const u32, len: usize, by: u32, out: *u64) void {
    nestedProvide(exported_with_zrx, ptr[0..len], by, out);
}

// --- flatten ------------------------------------------------------------------------

pub fn flattened(comptime with_zrx: bool, rows: []const [4]u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ flatten(), filter(isLarge), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(rows), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (rows) |row| {
            for (row) |value| {
                if (value >= 6) sum +%= value;
            }
        }
        out.* = sum;
    }
}

export fn same_flatten(ptr: [*]const [4]u32, len: usize, out: *u64) void {
    flattened(exported_with_zrx, ptr[0..len], out);
}

// --- early stop -----------------------------------------------------------------------------

pub fn taken(comptime with_zrx: bool, items: []const u32, limit: usize, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ filter(isEven), take(limit), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        var remaining = limit;
        for (items) |value| {
            if (value % 2 != 0) continue;
            if (remaining == 0) break;
            remaining -= 1;
            sum +%= value;
            if (remaining == 0) break;
        }
        out.* = sum;
    }
}

/// `lean`, not `same`: the optimizer picks a different loop form for the
/// early exit; the machine code is the same length either way.
export fn lean_take(ptr: [*]const u32, len: usize, limit: usize, out: *u64) void {
    taken(exported_with_zrx, ptr[0..len], limit, out);
}

// --- scan ---------------------------------------------------------------------------------------

fn addWide(sum: u64, value: u64) u64 {
    return sum +% value;
}

/// The sum of all prefix sums.
pub fn scanned(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ zrx.scan(@as(u64, 0), add), fold(@as(u64, 0), addWide), subscribe(store) });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var prefix: u64 = 0;
        var sum: u64 = 0;
        for (items) |value| {
            prefix +%= value;
            sum +%= prefix;
        }
        out.* = sum;
    }
}

export fn same_scan(ptr: [*]const u32, len: usize, out: *u64) void {
    scanned(exported_with_zrx, ptr[0..len], out);
}

// --- skip ---------------------------------------------------------------------------------------

pub fn skipped(comptime with_zrx: bool, items: []const u32, count: usize, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ zrx.skip(count), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        var remaining = count;
        for (items) |value| {
            if (remaining != 0) {
                remaining -= 1;
                continue;
            }
            sum +%= value;
        }
        out.* = sum;
    }
}

export fn same_skip(ptr: [*]const u32, len: usize, count: usize, out: *u64) void {
    skipped(exported_with_zrx, ptr[0..len], count, out);
}

// --- takeWhile ----------------------------------------------------------------------------------

const Limit = struct { below: u32 };

fn isBelow(limit: Limit, value: u32) bool {
    return value < limit.below;
}

pub fn takenWhile(comptime with_zrx: bool, items: []const u32, below: u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ zrx.takeWhile(isBelow), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(items), total), .{ Limit{ .below = below }, Result{ .out = out } });
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            if (value >= below) break;
            sum +%= value;
        }
        out.* = sum;
    }
}

export fn same_take_while(ptr: [*]const u32, len: usize, below: u32, out: *u64) void {
    takenWhile(exported_with_zrx, ptr[0..len], below, out);
}

// --- tap and drain ------------------------------------------------------------------------------

fn tally(result: Result, value: u32) void {
    result.out.* +%= value;
}

/// Adds every item to what `out` already holds.
pub fn tapped(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const work = pipe(.{ zrx.tap(tally), zrx.drain() });
        run(program(fromSlice(items), work), .{Result{ .out = out }});
    } else {
        for (items) |value| out.* +%= value;
    }
}

export fn same_tap_drain(ptr: [*]const u32, len: usize, out: *u64) void {
    tapped(exported_with_zrx, ptr[0..len], out);
}
