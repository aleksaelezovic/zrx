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

/// A run returns nothing. For a program that cannot fail that is all there
/// is to it: with anything left to fail with, this would not compile.
fn run(runnable: anytype, deps: anytype) void {
    runnable.run(deps);
}

/// Where a fixture that can fail says so: a flag its rescue sets, as the
/// hand-written loop sets it where it fails.
const Outcome = struct { failed: *bool };

fn noteFailed(outcome: Outcome, _: anyerror) void {
    outcome.failed.* = true;
}

/// Runs a program that can fail and says whether it came to its end.
fn ran(runnable: anytype, deps: anytype) bool {
    var failed = false;
    runnable.run(deps ++ .{ Outcome{ .failed = &failed }, zrx.rescue(noteFailed) });
    return !failed;
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

// --- route by what a predicate finds --------------------------------------------

/// The half of an even value: a predicate that finds what the case goes on with.
fn half(value: u32) ?u32 {
    return if (value % 2 == 0) value / 2 else null;
}
fn halfAndValue(even: zrx.Found(u32, u32)) u32 {
    return even.found +% even.item;
}

pub fn routedFound(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            route(.{ when(half, .{map(halfAndValue)}), otherwise(.{map(increment)}) }),
            fold(@as(u64, 0), add),
            forEach(store),
        });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            sum +%= if (half(value)) |found| found +% value else value +% 1;
        }
        out.* = sum;
    }
}

export fn same_route_found(ptr: [*]const u32, len: usize, out: *u64) void {
    routedFound(exported_with_zrx, ptr[0..len], out);
}

/// The same, where `all` asks a predicate first and answers what its last one found.
pub fn routedGuarded(comptime with_zrx: bool, items: []const u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            route(.{ when(zrx.all(.{ isLarge, half }), .{map(halfAndValue)}), otherwise(.{map(increment)}) }),
            fold(@as(u64, 0), add),
            forEach(store),
        });
        run(program(fromSlice(items), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            if (value >= 6) {
                if (half(value)) |found| {
                    sum +%= found +% value;
                    continue;
                }
            }
            sum +%= value +% 1;
        }
        out.* = sum;
    }
}

export fn same_route_guarded(ptr: [*]const u32, len: usize, out: *u64) void {
    routedGuarded(exported_with_zrx, ptr[0..len], out);
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
/// A value that was too small, as its error path sees it.
const TooSmall = zrx.Failed(error{TooSmall}, u32);

fn checked(value: u32) error{TooSmall}!u32 {
    if (value < 10) return error.TooSmall;
    return value;
}
fn countRejected(rejected: Rejected, _: TooSmall) void {
    rejected.count.* +%= 1;
}
fn accumulate(result: Result, value: u32) void {
    result.out.* +%= value;
}

pub fn recovered(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ recover(error{TooSmall}, .{forEach(countRejected)}), map(checked), tap(accumulate), drain() });
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

fn tooSmall(failed: TooSmall) u32 {
    return failed.item;
}
fn countOne(count: u32, _: u32) u32 {
    return count +% 1;
}
fn storeCount(rejected: Rejected, count: u32) void {
    rejected.count.* = count;
}

/// An error path with stages, state and an end of the stream of its own:
/// the even ones among the values that were too small, counted.
pub fn recoveredInto(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const counted = pipe(.{ map(tooSmall), filter(isEven), fold(@as(u32, 0), countOne), forEach(storeCount) });
        const total = pipe(.{ recover(error{TooSmall}, counted), map(checked), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        var sum: u64 = 0;
        var even: u32 = 0;
        for (items) |value| {
            if (value < 10) {
                if (value % 2 == 0) even +%= 1;
            } else {
                sum +%= value;
            }
        }
        rejected.* = even;
        out.* = sum;
    }
}

/// `lean`, not `same`: the pipeline keeps the branches of its two paths
/// where the optimizer turns the loop's inner `if` into selects.
export fn lean_recover_path(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) void {
    recoveredInto(exported_with_zrx, ptr[0..len], rejected, out);
}

/// An error path that wants no more ends the stream: the first value that
/// is too small is counted, and nothing after it is looked at.
pub fn recoveredOnce(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const first = pipe(.{ take(1), forEach(countRejected) });
        const total = pipe(.{ recover(error{TooSmall}, first), map(checked), fold(@as(u64, 0), add), forEach(store) });
        run(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        var sum: u64 = 0;
        for (items) |value| {
            if (value < 10) {
                rejected.* +%= 1;
                break;
            }
            sum +%= value;
        }
        out.* = sum;
    }
}

export fn same_recover_stop(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) void {
    recoveredOnce(exported_with_zrx, ptr[0..len], rejected, out);
}

/// A zero is not a rejection: the error path fails the run for it.
fn countOrFail(rejected: Rejected, failed: TooSmall) error{Zero}!void {
    if (failed.item == 0) return error.Zero;
    rejected.count.* +%= 1;
}

/// An error path that fails the run. Whether it did is the result.
pub fn recoveredOrFailed(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) bool {
    if (with_zrx) {
        const total = pipe(.{ recover(error{TooSmall}, .{forEach(countOrFail)}), map(checked), tap(accumulate), drain() });
        return !ran(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        for (items) |value| {
            if (value < 10) {
                if (value == 0) return true;
                rejected.* +%= 1;
            } else {
                out.* +%= value;
            }
        }
        return false;
    }
}

export fn same_recover_fail(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) bool {
    return recoveredOrFailed(exported_with_zrx, ptr[0..len], rejected, out);
}

// --- rescue -----------------------------------------------------------------------------

const Failure = struct { seen: *bool };

/// Names every error of the run: with it bound, nothing is left to return.
fn noteFailure(failure: Failure, err: anytype) void {
    switch (err) {
        error.Zero => failure.seen.* = true,
    }
}

/// The failure of the run goes to a binding instead of to the caller.
pub fn rescued(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64, failed: *bool) void {
    if (with_zrx) {
        const total = pipe(.{ recover(error{TooSmall}, .{forEach(countOrFail)}), map(checked), tap(accumulate), drain() });
        run(program(fromSlice(items), total), .{
            Rejected{ .count = rejected },
            Result{ .out = out },
            Failure{ .seen = failed },
            zrx.rescue(noteFailure),
        });
    } else {
        for (items) |value| {
            if (value < 10) {
                if (value == 0) {
                    failed.* = true;
                    return;
                }
                rejected.* +%= 1;
            } else {
                out.* +%= value;
            }
        }
    }
}

export fn same_rescue(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64, failed: *bool) void {
    rescued(exported_with_zrx, ptr[0..len], rejected, out, failed);
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
/// is everything around it. A failed write is noted in `failed`: by the
/// rescue of the run, and by hand where it happens.
pub fn printed(comptime with_zrx: bool, items: []const u32, writer: *std.Io.Writer, failed: *bool) void {
    if (with_zrx) {
        const lines = pipe(.{ filter(isEven), zrx.print(*std.Io.Writer, "{d}\n") });
        program(fromSlice(items), lines).run(.{ writer, Outcome{ .failed = failed }, zrx.rescue(noteFailed) });
    } else {
        for (items) |value| {
            if (value % 2 != 0) continue;
            writer.print("{d}\n", .{value}) catch {
                failed.* = true;
                return;
            };
            writer.flush() catch {
                failed.* = true;
                return;
            };
        }
        writer.flush() catch {
            failed.* = true;
        };
    }
}

export fn same_print(ptr: [*]const u32, len: usize, writer: *std.Io.Writer, failed: *bool) void {
    printed(exported_with_zrx, ptr[0..len], writer, failed);
}

/// `write` is `print` without the flush after each item. Its format differs
/// from the one in `printed` on purpose: two callers of one instantiation of
/// `std.Io.Writer.print` keep it out of line under a compiler-chosen name,
/// which differs between the two variants.
pub fn written(comptime with_zrx: bool, items: []const u32, writer: *std.Io.Writer, failed: *bool) void {
    if (with_zrx) {
        const lines = pipe(.{ filter(isEven), zrx.write(*std.Io.Writer, "{d},") });
        program(fromSlice(items), lines).run(.{ writer, Outcome{ .failed = failed }, zrx.rescue(noteFailed) });
    } else {
        for (items) |value| {
            if (value % 2 != 0) continue;
            writer.print("{d},", .{value}) catch {
                failed.* = true;
                return;
            };
        }
        writer.flush() catch {
            failed.* = true;
        };
    }
}

export fn same_write(ptr: [*]const u32, len: usize, writer: *std.Io.Writer, failed: *bool) void {
    written(exported_with_zrx, ptr[0..len], writer, failed);
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
/// The same, as the end of an error path.
fn halvedFailure(failed: TooSmall) u32 {
    return failed.item / 2;
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
        const total = pipe(.{ recover(error{TooSmall}, .{forEach(countRejected)}), map(zrx.require(zrx.ge(100), error.TooSmall)), tap(accumulate), drain() });
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

/// Halves summed, the values that have none counted: `require` over a
/// predicate that finds a value.
pub fn requiredFound(comptime with_zrx: bool, items: []const u32, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ recover(error{TooSmall}, .{forEach(countRejected)}), map(zrx.require(half, error.TooSmall)), tap(accumulate), drain() });
        run(program(fromSlice(items), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        for (items) |value| {
            if (half(value)) |found| {
                out.* +%= found;
            } else {
                rejected.* +%= 1;
            }
        }
    }
}

export fn same_require_found(ptr: [*]const u32, len: usize, rejected: *u32, out: *u64) void {
    requiredFound(exported_with_zrx, ptr[0..len], rejected, out);
}

// --- patterns of text (zrx.ext.pattern) -----------------------------------------------------------

const pattern = zrx.ext.pattern;

/// A text as a caller outside Zig hands one over.
pub const Text = extern struct { ptr: [*]const u8, len: usize };

fn bytes(text: Text) []const u8 {
    return text.ptr[0..text.len];
}
fn countText(count: u64, _: Text) u64 {
    return count +% 1;
}

const service_name = pattern.repeat(pattern.oneOf(.{ pattern.alnum, pattern.set("-_") }), .{ .min = 1 });

fn isServiceName(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return text.len != 0;
}

/// How many of the texts are service names: a pattern as a `filter`.
pub fn namesCounted(comptime with_zrx: bool, texts: []const Text, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ filter(zrx.compose(.{ bytes, service_name })), fold(@as(u64, 0), countText), forEach(store) });
        run(program(fromSlice(texts), total), .{Result{ .out = out }});
    } else {
        var count: u64 = 0;
        for (texts) |text| {
            if (isServiceName(bytes(text))) count +%= 1;
        }
        out.* = count;
    }
}

/// `lean`, not `same`: a pattern carries its position through its parts and
/// asks at the end whether that is the end of the text, where the loop
/// leaves at the first byte that is wrong. What is done for a byte is the same.
export fn lean_pattern_filter(ptr: [*]const Text, len: usize, out: *u64) void {
    namesCounted(exported_with_zrx, ptr[0..len], out);
}

const item_path = pattern.seq(.{ "/items/", pattern.extract(.id, pattern.int(u32)) });

fn itemId(text: []const u8) ?u32 {
    const prefix = "/items/";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    var id: u32 = 0;
    for (text[prefix.len..]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        id = std.math.mul(u32, id, 10) catch return null;
        id = std.math.add(u32, id, c - '0') catch return null;
    }
    return if (text.len == prefix.len) null else id;
}
fn addId(sum: u64, item: anytype) u64 {
    return sum +% item.found.id;
}

/// The ids of the texts that are item paths summed, the other texts
/// counted: a pattern that extracts, as the predicate of a case.
pub fn pathsRouted(comptime with_zrx: bool, texts: []const Text, ids: *u64, others: *u64) void {
    if (with_zrx) {
        const sorted = pipe(.{route(.{
            when(zrx.compose(.{ bytes, item_path }), .{ fold(@as(u64, 0), addId), forEach(store) }),
            otherwise(.{ fold(@as(u64, 0), countText), forEach(storeSecond) }),
        })});
        run(program(fromSlice(texts), sorted), .{ Result{ .out = ids }, Second{ .out = others } });
    } else {
        var sum: u64 = 0;
        var rest: u64 = 0;
        for (texts) |text| {
            if (itemId(bytes(text))) |id| sum +%= id else rest +%= 1;
        }
        ids.* = sum;
        others.* = rest;
    }
}

/// `lean`, not `same`, for the reason given at `lean_pattern_filter`: the
/// prefix is not cut off, the position goes on from behind it.
export fn lean_pattern_route(ptr: [*]const Text, len: usize, ids: *u64, others: *u64) void {
    pathsRouted(exported_with_zrx, ptr[0..len], ids, others);
}

const reading = pattern.seq(.{ pattern.extract(.ts_ms, pattern.int(u64)), ",", pattern.extract(.temp_mc, pattern.int(i32)) });
const InvalidReading = zrx.Failed(error{TooSmall}, Text);

fn readingOf(text: []const u8) ?struct { ts_ms: u64, temp_mc: i32 } {
    var at: usize = 0;
    var ts_ms: u64 = 0;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {
        ts_ms = std.math.mul(u64, ts_ms, 10) catch return null;
        ts_ms = std.math.add(u64, ts_ms, text[at] - '0') catch return null;
    }
    if (at == 0 or at == text.len or text[at] != ',') return null;
    at += 1;
    const negative = at < text.len and text[at] == '-';
    if (negative) at += 1;
    const from = at;
    var temp_mc: i32 = 0;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {
        const next: i32 = text[at] - '0';
        temp_mc = std.math.mul(i32, temp_mc, 10) catch return null;
        temp_mc = (if (negative) std.math.sub(i32, temp_mc, next) else std.math.add(i32, temp_mc, next)) catch return null;
    }
    if (at == from or at != text.len) return null;
    return .{ .ts_ms = ts_ms, .temp_mc = temp_mc };
}
fn countInvalid(rejected: Rejected, _: InvalidReading) void {
    rejected.count.* +%= 1;
}
fn addTemperature(result: Result, found: anytype) void {
    result.out.* +%= @as(u32, @bitCast(found.temp_mc));
}

/// The temperatures of the readings summed, the texts that are no reading
/// counted: `require` over a pattern that extracts two numbers.
pub fn readingsRequired(comptime with_zrx: bool, texts: []const Text, rejected: *u32, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            recover(error{TooSmall}, .{forEach(countInvalid)}),
            map(zrx.require(zrx.compose(.{ bytes, reading }), error.TooSmall)),
            tap(addTemperature),
            drain(),
        });
        run(program(fromSlice(texts), total), .{ Rejected{ .count = rejected }, Result{ .out = out } });
    } else {
        for (texts) |text| {
            if (readingOf(bytes(text))) |found| {
                out.* +%= @as(u32, @bitCast(found.temp_mc));
            } else {
                rejected.* +%= 1;
            }
        }
    }
}

/// `lean`, not `same`: as many instructions as the scanner above, in another
/// order, as the pattern asks "is this the end" once where the scanner asks
/// it with the last number.
export fn lean_pattern_require(ptr: [*]const Text, len: usize, rejected: *u32, out: *u64) void {
    readingsRequired(exported_with_zrx, ptr[0..len], rejected, out);
}

/// A row of a file, as a line source emits it, and the name of a sensor.
pub const Row = zrx.Line(32);
pub const Sensor = zrx.Line(8);
const Latest = struct { sensor: *Sensor };

const letters = pattern.repeat(pattern.lower, .{ .min = 1 });
const named_reading = pattern.seq(.{ pattern.extract(.sensor, pattern.as(Sensor, letters)), ",", pattern.extract(.temp_mc, pattern.int(i32)) });

fn namedReadingOf(row: *const Row) ?struct { sensor: Sensor, temp_mc: i32 } {
    const text = row.text();
    var at: usize = 0;
    while (at < text.len and std.ascii.isLower(text[at])) at += 1;
    if (at == 0) return null;
    const sensor = Sensor.from(text[0..at]) catch return null;
    if (at == text.len or text[at] != ',') return null;
    at += 1;
    const negative = at < text.len and text[at] == '-';
    if (negative) at += 1;
    const from = at;
    var temp_mc: i32 = 0;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {
        const next: i32 = text[at] - '0';
        temp_mc = std.math.mul(i32, temp_mc, 10) catch return null;
        temp_mc = (if (negative) std.math.sub(i32, temp_mc, next) else std.math.add(i32, temp_mc, next)) catch return null;
    }
    if (at == from or at != text.len) return null;
    return .{ .sensor = sensor, .temp_mc = temp_mc };
}
fn noteReading(result: Result, latest: Latest, seen: anytype) void {
    result.out.* +%= @as(u32, @bitCast(seen.found.temp_mc));
    latest.sensor.* = seen.found.sensor;
}
fn countRow(second: Second, _: Row) void {
    second.out.* +%= 1;
}

/// The temperatures of the rows that are readings summed and the sensor of
/// the last one kept, the other rows counted: a pattern put to a line, which
/// keeps a name as a value.
pub fn rowsRouted(comptime with_zrx: bool, rows: []const Row, sum: *u64, sensor: *Sensor, others: *u64) void {
    if (with_zrx) {
        const sorted = pipe(.{route(.{
            when(named_reading, .{forEach(noteReading)}),
            otherwise(.{forEach(countRow)}),
        })});
        run(program(fromSlice(rows), sorted), .{ Result{ .out = sum }, Latest{ .sensor = sensor }, Second{ .out = others } });
    } else {
        for (rows) |*each| {
            // An item reaches a stage as a value: see `lean_pattern_line`.
            const row = each.*;
            if (namedReadingOf(&row)) |found| {
                sum.* +%= @as(u32, @bitCast(found.temp_mc));
                sensor.* = found.sensor;
            } else {
                others.* +%= 1;
            }
        }
    }
}

/// `lean`, not `same`, for the reason given at `lean_pattern_filter`.
///
/// The loop by hand copies each row before it reads it, which nobody would
/// write. An item goes from stage to stage as a value, and in this pipe
/// the optimizer does not take that copy out: one `memcpy` of the row,
/// with a function of one's own as the predicate just as with a pattern.
/// That is a measurement of this pipe, not a rule for others. It is in
/// both loops so that what is compared is the pattern. Without it the loop
/// by hand has 107 instructions and no copy. `same_line_reference` is the
/// pipe that has none either.
export fn lean_pattern_line(ptr: [*]const Row, len: usize, sum: *u64, sensor: *Sensor, others: *u64) void {
    rowsRouted(exported_with_zrx, ptr[0..len], sum, sensor, others);
}

fn allLower(row: *const Row) bool {
    for (row.text()) |c| if (!std.ascii.isLower(c)) return false;
    return row.len != 0;
}
fn lengthOfRow(row: *const Row) u64 {
    return row.len;
}

/// The lengths of the rows that are all letters, summed, where the items
/// are references to rows and not rows: a handler scans the bytes where
/// they are, and nothing is copied.
pub fn referencesScanned(comptime with_zrx: bool, rows: []const *const Row, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ filter(allLower), map(lengthOfRow), fold(@as(u64, 0), addWide), forEach(store) });
        run(program(fromSlice(rows), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (rows) |row| {
            if (allLower(row)) sum +%= row.len;
        }
        out.* = sum;
    }
}

export fn same_line_reference(ptr: [*]const *const Row, len: usize, out: *u64) void {
    referencesScanned(exported_with_zrx, ptr[0..len], out);
}

// --- text handlers and sources (zrx.ext.text) -----------------------------------------------------

const txt = zrx.ext.text;

fn addLength(sum: u64, piece: []const u8) u64 {
    return sum +% piece.len;
}
fn longer(longest: u64, piece: []const u8) u64 {
    return @max(longest, piece.len);
}

/// The length of all the texts without the blanks at their edges: `trim`
/// put to a text that stays where it is.
pub fn trimmedLength(comptime with_zrx: bool, texts: []const Text, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(bytes), map(txt.trim(" \t")), fold(@as(u64, 0), addLength), forEach(store) });
        run(program(fromSlice(texts), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (texts) |each| sum +%= std.mem.trim(u8, bytes(each), " \t").len;
        out.* = sum;
    }
}

export fn same_text_trim(ptr: [*]const Text, len: usize, out: *u64) void {
    trimmedLength(exported_with_zrx, ptr[0..len], out);
}

/// For every text its longest column, summed: `each` over `split`.
pub fn longestColumns(comptime with_zrx: bool, texts: []const Text, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            zrx.each(zrx.compose(.{ bytes, txt.split(",") }), .{fold(@as(u64, 0), longer)}),
            map(zrx.field(.item)),
            fold(@as(u64, 0), addWide),
            forEach(store),
        });
        run(program(fromSlice(texts), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (texts) |each| {
            var columns = std.mem.splitScalar(u8, bytes(each), ',');
            var longest: u64 = 0;
            while (columns.next()) |column| longest = @max(longest, column.len);
            sum +%= longest;
        }
        out.* = sum;
    }
}

/// The source is `std.mem.splitScalar` and the loop over it: no call and no
/// stack slot on either side.
export fn same_text_split(ptr: [*]const Text, len: usize, out: *u64) void {
    longestColumns(exported_with_zrx, ptr[0..len], out);
}

/// For every text its longest word, summed: `each` over `tokenize`.
pub fn longestWords(comptime with_zrx: bool, texts: []const Text, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{
            zrx.each(zrx.compose(.{ bytes, txt.tokenize(" \t") }), .{fold(@as(u64, 0), longer)}),
            map(zrx.field(.item)),
            fold(@as(u64, 0), addWide),
            forEach(store),
        });
        run(program(fromSlice(texts), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (texts) |each| {
            var words = std.mem.tokenizeAny(u8, bytes(each), " \t");
            var longest: u64 = 0;
            while (words.next()) |word| longest = @max(longest, word.len);
            sum +%= longest;
        }
        out.* = sum;
    }
}

export fn same_text_tokenize(ptr: [*]const Text, len: usize, out: *u64) void {
    longestWords(exported_with_zrx, ptr[0..len], out);
}

fn addBytes(sum: u64, row: Row) u64 {
    var next = sum;
    for (row.text()) |byte| next +%= byte;
    return next;
}

/// `trim` put to a line, by hand: see `same_text_trim_line`.
fn trimRow(data: struct { Row }) Row {
    const kept = std.mem.trim(u8, data[0].text(), " \t");
    var trimmed: Row = .{ .bytes = undefined, .len = kept.len };
    @memcpy(trimmed.bytes[0..kept.len], kept);
    return trimmed;
}

/// The bytes of the rows without the blanks at their edges, summed: `trim`
/// put to a line, which answers a line.
pub fn rowsTrimmed(comptime with_zrx: bool, rows: []const Row, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(txt.trim(" \t")), fold(@as(u64, 0), addBytes), forEach(store) });
        run(program(fromSlice(rows), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (rows) |row| sum = addBytes(sum, trimRow(.{row}));
        out.* = sum;
    }
}

/// The loop by hand trims each row in a function of its own, which it
/// gives the row as a tuple of one, as a handler is given its data. Written
/// inline, the two differ in where a stack slot begins and ends (a
/// function's slots are marked for each call once it is inlined) and in a
/// store of a zero that the pipe has not; given the row alone, in the type
/// of that stack slot and nothing else.
///
/// Measured on both sides, for this pipe and both targets: the row copied
/// once, into the tuple, and what is kept copied once, into the new line.
/// An item goes from stage to stage as a value, and in this pipe the
/// optimizer does not take the first copy out (see `lean_pattern_line`).
/// That is a measurement of this pipe, not a rule for others.
export fn same_text_trim_line(ptr: [*]const Row, len: usize, out: *u64) void {
    rowsTrimmed(exported_with_zrx, ptr[0..len], out);
}

/// The bytes of the rows in upper case, summed: `toUpper` put to a line.
pub fn rowsUpper(comptime with_zrx: bool, rows: []const Row, out: *u64) void {
    if (with_zrx) {
        const total = pipe(.{ map(txt.toUpper), fold(@as(u64, 0), addBytes), forEach(store) });
        run(program(fromSlice(rows), total), .{Result{ .out = out }});
    } else {
        var sum: u64 = 0;
        for (rows) |*each| {
            var upper = each.*;
            for (upper.bytes[0..upper.len]) |*byte| byte.* = std.ascii.toUpper(byte.*);
            for (upper.text()) |byte| sum +%= byte;
        }
        out.* = sum;
    }
}

/// The loop by hand copies each row and converts the copy, where one would
/// convert the bytes as one reads them. An item reaches a stage as a value
/// (see `lean_pattern_line`), and the handler converts the one it was
/// given: in this pipe that is the row copied once, on both sides. With a
/// sink that stores the row, where this one reads it, the pipe measured
/// one copy of the row's bytes and one stack slot more than the loop by
/// hand (41 instructions to 35 on aarch64). `docs/spec-text.md` has both.
export fn same_text_upper(ptr: [*]const Row, len: usize, out: *u64) void {
    rowsUpper(exported_with_zrx, ptr[0..len], out);
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
            zrx.attempt(.{ map(checked), map(triple) }, error{TooSmall}, .{map(halvedFailure)}),
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
/// and the error path, and the optimizer keeps the branch between them where
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
            zrx.attempt(.{ map(checked), map(triple) }, error{TooSmall}, .{map(halvedFailure)}),
            map(capped),
            fold(@as(u64, 0), add),
            forEach(store),
        });
        if (!ran(program(fromSlice(items), total), .{Result{ .out = out }})) return false;
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
