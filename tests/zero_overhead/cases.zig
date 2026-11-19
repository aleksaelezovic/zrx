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
const branch = zrx.branch;
const route = zrx.route;
const when = zrx.when;
const otherwise = zrx.otherwise;
const forEach = zrx.forEach;
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
        run(program(fromSlice(items), .{ map(scale), filter(isLarge), fold(@as(u64, 0), add), forEach(store) }), .{ Scale{ .by = by }, Result{ .out = out } });
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
        const scaled = pipe(.{map(scale)});
        const even = pipe(.{ scaled, pipe(.{filter(isEven)}) });
        const total = pipe(.{ even, pipe(.{ fold(@as(u64, 0), add), forEach(store) }) });
        run(program(fromSlice(items), total).provide(.{ Scale{ .by = by }, Result{ .out = out } }), .{});
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
            route(.{ when(isEven, .{map(triple)}), otherwise(.{map(increment)}) }),
            fold(@as(u64, 0), add),
            forEach(store),
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
            .{ fold(@as(u64, 0), add), forEach(store) },
            pipe(.{ filter(isEven), map(triple), fold(@as(u64, 0), add), forEach(storeSecond) }),
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
        const total = pipe(.{ flatten(), filter(isLarge), fold(@as(u64, 0), add), forEach(store) });
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
        const total = pipe(.{ filter(wanted), map(zrx.field(.price)), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(orders), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (orders) |order| {
            if (order.price >= 100 and order.id % 2 != 0) sum +%= order.price;
        }
        out.* = sum;
    }
}

/// `lean`, not `same`: the pipeline reads the whole order once where the loop
/// reads its two fields separately; the pipeline comes out shorter.
export fn lean_combinators(ptr: [*]const Order, len: usize, out: *u64) void {
    combined(exported_with_zrx, ptr[0..len], out);
}

// --- early stop -----------------------------------------------------------------------------

pub fn taken(comptime with_zrx: bool, items: []const u32, limit: usize, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ filter(isEven), take(limit), fold(@as(u64, 0), add), forEach(store) });
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
        const total = pipe(.{ zrx.scan(@as(u64, 0), add), fold(@as(u64, 0), addWide), forEach(store) });
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
        const total = pipe(.{ zrx.skip(count), fold(@as(u64, 0), add), forEach(store) });
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
        const total = pipe(.{ zrx.takeWhile(isBelow), fold(@as(u64, 0), add), forEach(store) });
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

// --- batch --------------------------------------------------------------------------------------

/// The largest item of a group, times how many items the group has.
fn weigh(group: []const u32) u64 {
    var largest: u32 = 0;
    for (group) |value| largest = @max(largest, value);
    return @as(u64, largest) *% group.len;
}

fn weighBatch(group: zrx.Batch(u32, 4)) u64 {
    return weigh(group.slice());
}

pub fn batched(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ zrx.batch(4), map(weighBatch), fold(@as(u64, 0), addWide), forEach(store) });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        var group: [4]u32 = undefined;
        var len: usize = 0;
        for (items) |value| {
            group[len] = value;
            len += 1;
            if (len == group.len) {
                sum +%= weigh(&group);
                len = 0;
            }
        }
        if (len != 0) sum +%= weigh(group[0..len]);
        out.* = sum;
    }
}

/// `lean`, not `same`: both variants are the same size, but the optimizer
/// unrolls the two differently around the four-item buffer.
export fn lean_batch(ptr: [*]const u32, len: usize, out: *u64) void {
    batched(exported_with_zrx, ptr[0..len], out);
}

// --- resource -----------------------------------------------------------------------------------

const Ledger = struct { opened: *u32, closed: *u32 };
const Session = struct { bias: u32 };

fn open(ledger: Ledger) Session {
    ledger.opened.* +%= 1;
    return .{ .bias = ledger.opened.* };
}
fn close(ledger: Ledger, session: Session) void {
    ledger.closed.* +%= session.bias;
}
fn biased(session: Session, value: u32) u32 {
    return value +% session.bias;
}

pub fn withResource(comptime with_zrx: bool, items: []const u32, opened: *u32, closed: *u32, out: *u64) void {
    const ledger: Ledger = .{ .opened = opened, .closed = closed };
    if (with_zrx) {
        const total = pipe(.{ map(biased), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(items), total).provide(.{zrx.resource(open, close)}), .{ ledger, Result{ .out = out } });
    } else {
        const session = open(ledger);
        defer close(ledger, session);
        var sum: u64 = 0;
        for (items) |value| sum +%= value +% session.bias;
        out.* = sum;
    }
}

export fn same_resource(ptr: [*]const u32, len: usize, opened: *u32, closed: *u32, out: *u64) void {
    withResource(exported_with_zrx, ptr[0..len], opened, closed, out);
}

// --- bindings in any order ----------------------------------------------------------------------

const Rate = struct { by: u32 };

fn rateOf(session: Session) Rate {
    return .{ .by = session.bias +% 1 };
}
fn never(ledger: Ledger) Scale {
    ledger.closed.* = 0;
    return .{ .by = 0 };
}
fn scaledAtRate(factor: Scale, rate: Rate, value: u32) u32 {
    return value *% factor.by +% rate.by;
}

/// The rate needs the session, which needs the ledger: written the other way
/// round, in `provide` and in `run`. The default scale is replaced and never
/// acquired. The order is worked out at compile time and leaves nothing behind.
pub fn withBindings(comptime with_zrx: bool, items: []const u32, by: u32, opened: *u32, closed: *u32, out: *u64) void {
    const ledger: Ledger = .{ .opened = opened, .closed = closed };
    if (with_zrx) {
        const total = pipe(.{ map(scaledAtRate), fold(@as(u64, 0), add), forEach(store) });
        const app = program(fromSlice(items), total).provide(.{ zrx.resource(rateOf, null), zrx.resource(never, null) });
        run(app, .{ zrx.resource(open, close), Scale{ .by = by }, Result{ .out = out }, ledger });
    } else {
        const session = open(ledger);
        defer close(ledger, session);
        const rate = session.bias +% 1;
        var sum: u64 = 0;
        for (items) |value| sum +%= value *% by +% rate;
        out.* = sum;
    }
}

export fn same_bindings(ptr: [*]const u32, len: usize, by: u32, opened: *u32, closed: *u32, out: *u64) void {
    withBindings(exported_with_zrx, ptr[0..len], by, opened, closed, out);
}

// --- print --------------------------------------------------------------------------------------

/// Formatting is a call into `std.Io.Writer` in both variants; what must match
/// is everything around it.
pub fn printed(comptime with_zrx: bool, items: []const u32, writer: *std.Io.Writer) bool {
    if (with_zrx) {
        const lines = pipe(.{ filter(isEven), zrx.print(*std.Io.Writer, "{d}\n") });
        program(fromSlice(items), lines).run(.{writer}) catch return false;
    } else {
        for (items) |value| {
            if (value % 2 != 0) continue;
            writer.print("{d}\n", .{value}) catch return false;
            writer.flush() catch return false;
        }
        writer.flush() catch return false;
    }
    return true;
}

export fn same_print(ptr: [*]const u32, len: usize, writer: *std.Io.Writer) bool {
    return printed(exported_with_zrx, ptr[0..len], writer);
}

/// `write` is `print` without the flush after each item. Its format differs
/// from the one in `printed` on purpose: two callers of one instantiation of
/// `std.Io.Writer.print` keep it out of line under a compiler-chosen name,
/// which differs between the two variants.
pub fn written(comptime with_zrx: bool, items: []const u32, writer: *std.Io.Writer) bool {
    if (with_zrx) {
        const lines = pipe(.{ filter(isEven), zrx.write(*std.Io.Writer, "{d},") });
        program(fromSlice(items), lines).run(.{writer}) catch return false;
    } else {
        for (items) |value| {
            if (value % 2 != 0) continue;
            writer.print("{d},", .{value}) catch return false;
        }
        writer.flush() catch return false;
    }
    return true;
}

export fn same_write(ptr: [*]const u32, len: usize, writer: *std.Io.Writer) bool {
    return written(exported_with_zrx, ptr[0..len], writer);
}

// --- reduce -------------------------------------------------------------------------------------

fn widest(most: u32, value: u32) u32 {
    return @max(most, value);
}

/// The largest value of every row, summed.
pub fn reduced(comptime with_zrx: bool, rows: []const [4]u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(zrx.reduce(0, widest)), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(rows), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (rows) |row| {
            var most: u32 = 0;
            for (row) |value| most = @max(most, value);
            sum +%= most;
        }
        out.* = sum;
    }
}

export fn same_reduce(ptr: [*]const [4]u32, len: usize, out: *u64) void {
    reduced(exported_with_zrx, ptr[0..len], out);
}

// --- orElse -------------------------------------------------------------------------------------

fn halved(_: error{TooSmall}, value: u32) u32 {
    return value / 2;
}

/// Small values count for half instead of being dropped.
pub fn fellBack(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(zrx.orElse(checked, halved)), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (items) |value| sum +%= if (value < 10) value / 2 else value;
        out.* = sum;
    }
}

export fn same_or_else(ptr: [*]const u32, len: usize, out: *u64) void {
    fellBack(exported_with_zrx, ptr[0..len], out);
}

// --- require ------------------------------------------------------------------------------------

/// Large values summed, the others counted. The error is the one `recovered`
/// already has, on purpose: the integer behind an error shifts when the file
/// gains a name, and with it the form the optimizer gives the comparison in
/// `same_recover`.
pub fn required(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ recover(countRejected), map(zrx.require(zrx.ge(100), error.TooSmall)), tap(accumulate), drain() });
        run(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        for (items) |value| {
            if (value < 100) {
                rejected.* +%= 1;
            } else {
                out.* +%= value;
            }
        }
    }
}

export fn same_require(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) void {
    required(exported_with_zrx, ptr[0..len], rejected, out);
}

// --- each ---------------------------------------------------------------------------------------

/// Some values and what their sum counts for.
pub const Group = extern struct { ptr: [*]const u32, len: usize, weight: u32 };

const Values = @TypeOf(fromSlice(@as([]const u32, &.{})));

fn valuesOf(group: Group) Values {
    return fromSlice(group.ptr[0..group.len]);
}
fn weighted(sum: zrx.Tagged(Group, u64)) u64 {
    return sum.item *% sum.source.weight;
}

/// For every group, the sum of its large values times its weight.
pub fn nested(comptime with_zrx: bool, groups: []const Group, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            zrx.each(valuesOf, .{ filter(isLarge), fold(@as(u64, 0), add) }),
            map(weighted),
            fold(@as(u64, 0), addWide),
            forEach(store),
        });
        run(program(fromSlice(groups), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (groups) |group| {
            var inner: u64 = 0;
            for (group.ptr[0..group.len]) |value| {
                if (value >= 6) inner +%= value;
            }
            sum +%= inner *% group.weight;
        }
        out.* = sum;
    }
}

export fn same_each(ptr: [*]const Group, len: usize, out: *u64) void {
    nested(exported_with_zrx, ptr[0..len], out);
}

// --- attempt ------------------------------------------------------------------------------------

/// Small values count for half; the others are tripled.
pub fn attempted(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            zrx.attempt(.{ map(checked), map(triple) }, halved),
            fold(@as(u64, 0), add),
            forEach(store),
        });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (items) |value| sum +%= if (value < 10) value / 2 else value *% 3;
        out.* = sum;
    }
}

/// `lean`, not `same`: the pipeline pushes on from two places, the sub-pipe
/// and the fallback, and the optimizer keeps the branch between them where
/// the loop's one expression becomes a select. Three instructions more.
export fn lean_attempt(ptr: [*]const u32, len: usize, out: *u64) void {
    attempted(exported_with_zrx, ptr[0..len], out);
}

fn capped(value: u32) error{TooLarge}!u32 {
    if (value > 1000) return error.TooLarge;
    return value;
}

/// The same with a pipe after the `attempt` that can fail. Its failure is
/// not the sub-pipe's, and telling the two apart must cost nothing.
pub fn attemptedCapped(comptime with_zrx: bool, items: []const u32, out: *u64) bool {
    if (with_zrx) {
        const total = pipe(.{
            zrx.attempt(.{ map(checked), map(triple) }, halved),
            map(capped),
            fold(@as(u64, 0), add),
            forEach(store),
        });
        program(fromSlice(items), total).run(.{Result{ .out = out }}) catch return false;
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            const counted = if (value < 10) value / 2 else value *% 3;
            if (counted > 1000) return false;
            sum +%= counted;
        }
        out.* = sum;
    }
    return true;
}

/// `lean` for the same reason, with the comparison of `capped` on both paths.
export fn lean_attempt_failing(ptr: [*]const u32, len: usize, out: *u64) bool {
    return attemptedCapped(exported_with_zrx, ptr[0..len], out);
}
