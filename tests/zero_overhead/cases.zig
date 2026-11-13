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
const tap = zrx.tap;
const fold = zrx.fold;
const take = zrx.take;
const flatten = zrx.flatten;
const recover = zrx.recover;
const provide = zrx.provide;
const branch = zrx.branch;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const subscribe = zrx.subscribe;
const drain = zrx.drain;

/// Which variant the exported functions are compiled as.
const exported_with_zrx = @import("variant").with_zrx;

const Scale = struct { by: u32 };
const Result = struct { out: *u64 };
const Second = struct { out: *u64 };

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
fn storeSecond(result: Second, value: u64) void {
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

// --- route with rejoining cases -------------------------------------------------

fn triple(value: u32) u32 {
    return value *% 3;
}
fn increment(value: u32) u32 {
    return value +% 1;
}

pub fn routed(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            route(.{ when(isEven, pipe(.{map(triple)})), otherwise(pipe(.{map(increment)})) }),
            fold(@as(u64, 0), add),
            subscribe(store),
        });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            sum +%= if (value % 2 == 0) value *% 3 else value +% 1;
        }
        out.* = sum;
    }
}

export fn same_route(ptr: [*]const u32, len: usize, out: *u64) void {
    routed(exported_with_zrx, ptr[0..len], out);
}

// --- branch into two folds --------------------------------------------------------

pub fn branched(comptime with_zrx: bool, items: []const u32, first: *u64, second: *u64) void {
    if (with_zrx) {
        const totals = pipe(.{branch(.{
            pipe(.{ fold(@as(u64, 0), add), subscribe(store) }),
            pipe(.{ filter(isEven), map(triple), fold(@as(u64, 0), add), subscribe(storeSecond) }),
        })});
        run(program(fromSlice(items), totals), .{ Result{ .out = first }, Second{ .out = second } });
    } else {
        var sum: u64 = 0;
        var evens: u64 = 0;
        for (items) |value| {
            sum +%= value;
            if (value % 2 == 0) evens +%= value *% 3;
        }
        first.* = sum;
        second.* = evens;
    }
}

export fn same_branch(ptr: [*]const u32, len: usize, first: *u64, second: *u64) void {
    branched(exported_with_zrx, ptr[0..len], first, second);
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

// --- recover --------------------------------------------------------------------------

const Rejected = struct { count: *u32 };

fn checked(value: u32) error{TooSmall}!u32 {
    if (value < 10) return error.TooSmall;
    return value;
}
fn countRejected(rejected: Rejected, _: error{TooSmall}, _: u32) void {
    rejected.count.* +%= 1;
}
fn accumulate(result: Result, value: u32) void {
    result.out.* +%= value;
}

pub fn recovered(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ recover(countRejected), map(checked), tap(accumulate), drain() });
        run(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        for (items) |value| {
            if (value < 10) {
                rejected.* +%= 1;
            } else {
                out.* +%= value;
            }
        }
    }
}

export fn same_recover(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) void {
    recovered(exported_with_zrx, ptr[0..len], rejected, out);
}

// --- handler combinators ----------------------------------------------------------------

pub const Order = extern struct { id: u32, price: u32 };

pub fn combined(comptime with_zrx: bool, orders: []const Order, out: *u64) void {
    if (with_zrx) {
        const wanted = zrx.all(.{
            zrx.compose(.{ zrx.field(.price), zrx.ge(100) }),
            zrx.not(zrx.compose(.{ zrx.field(.id), isEven })),
        });
        const total = pipe(.{ filter(wanted), map(zrx.field(.price)), fold(@as(u64, 0), add), subscribe(store) });
        run(program(fromSlice(orders), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (orders) |order| {
            if (order.price >= 100 and order.id % 2 != 0) sum +%= order.price;
        }
        out.* = sum;
    }
}

export fn lean_combinators(ptr: [*]const Order, len: usize, out: *u64) void {
    combined(exported_with_zrx, ptr[0..len], out);
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

export fn lean_take(ptr: [*]const u32, len: usize, limit: usize, out: *u64) void {
    taken(exported_with_zrx, ptr[0..len], limit, out);
}
