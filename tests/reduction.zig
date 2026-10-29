const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const filter = zrx.filter;
const each = zrx.each;
const fold = zrx.fold;
const tryFold = zrx.tryFold;
const tapWith = zrx.tapWith;

fn add(total: u64, value: u32) u64 {
    return total +% value;
}

fn checkedAdd(total: u64, value: u32) error{Zero}!u64 {
    if (value == 0) return error.Zero;
    return add(total, value);
}

fn even(value: u32) bool {
    return value % 2 == 0;
}

fn twice(value: u32) u32 {
    return value *% 2;
}

fn increment(value: u32) u32 {
    return value +% 1;
}

test "runtime seeds, element coercions, literal seeds, and comptime execution" {
    const Helpers = struct {
        fn run(values: []const u8, initial: u16) u64 {
            return pipe(values, .{fold(initial, add)});
        }
    };
    const values = [_]u8{ 1, 2, 3 };
    const result = pipe(&values, .{fold(5, add)});
    try std.testing.expectEqual(u64, @TypeOf(result));
    try std.testing.expectEqual(@as(u64, 11), result);
    try std.testing.expectEqual(@as(u64, 13), Helpers.run(&values, 7));
    try std.testing.expectEqual(@as(u64, 11), comptime pipe(&values, .{fold(5, add)}));
    try std.testing.expectEqual(@as(u64, 11), try pipe(&values, .{tryFold(5, checkedAdd)}));
    try std.testing.expectEqual(error{Zero}!u64, @TypeOf(pipe(&values, .{tryFold(5, checkedAdd)})));
    try std.testing.expectEqual(error{}!u64, @TypeOf(tryPipe(&values, .{fold(5, add)})));
}

test "both folds return the seed on empty and all-filtered inputs without calling reducers" {
    const Helpers = struct {
        var calls: usize = 0;
        fn count(total: u32, value: u32) u32 {
            calls += 1;
            return total + value;
        }
        fn checked(total: u32, value: u32) error{}!u32 {
            return count(total, value);
        }
    };
    Helpers.calls = 0;
    const empty = [_]u32{};
    const rejected = [_]u32{ 1, 3, 5 };
    try std.testing.expectEqual(@as(u32, 7), pipe(&empty, .{fold(7, Helpers.count)}));
    try std.testing.expectEqual(@as(u32, 7), try pipe(&empty, .{tryFold(7, Helpers.checked)}));
    try std.testing.expectEqual(@as(u32, 7), pipe(&rejected, .{ filter(even), fold(7, Helpers.count) }));
    try std.testing.expectEqual(@as(u32, 7), try pipe(&rejected, .{ filter(even), tryFold(7, Helpers.checked) }));
    try std.testing.expectEqual(@as(usize, 0), Helpers.calls);
}

test "fold is a left fold and grouped/separate upstream each forms agree" {
    const Helpers = struct {
        fn append(total: u64, value: u32) u64 {
            return total * 10 + value;
        }
    };
    const values = [_]u32{ 1, 2, 3 };
    try std.testing.expectEqual(@as(u64, 9123), pipe(&values, .{fold(9, Helpers.append)}));
    const grouped = pipe(&values, .{ each(.{ twice, increment }), fold(0, add) });
    const separate = pipe(&values, .{ each(twice), each(.{increment}), fold(0, add) });
    try std.testing.expectEqual(@as(u64, 15), grouped);
    try std.testing.expectEqual(grouped, separate);
    try std.testing.expectEqual(grouped, try tryPipe(&values, .{
        each(.{ twice, increment }),
        tryFold(0, checkedAdd),
    }));
}

test "construction is lazy and consumption interleaves callbacks in source order" {
    const Helpers = struct {
        var trace: [16]u32 = undefined;
        var used: usize = 0;
        fn log(value: u32) void {
            trace[used] = value;
            used += 1;
        }
        fn accept(value: u32) bool {
            log(100 + value);
            return even(value);
        }
        fn transform(value: u32) u32 {
            log(200 + value);
            return value * 2;
        }
        fn accumulate(total: u64, value: u32) u64 {
            log(300 + value);
            return add(total, value);
        }
    };
    Helpers.used = 0;
    var values = [_]u32{ 1, 2, 3, 4 };
    const view = pipe(&values, .{ filter(Helpers.accept), each(Helpers.transform) });
    const operation = fold(5, Helpers.accumulate);
    try std.testing.expectEqual(@as(usize, 0), Helpers.used);
    try std.testing.expectEqual(@as(u64, 17), pipe(view, .{operation}));
    try std.testing.expectEqualSlices(u32, &.{ 101, 102, 202, 304, 103, 104, 204, 308 }, Helpers.trace[0..Helpers.used]);
    values[0] = 6;
    Helpers.used = 0;
    try std.testing.expectEqual(@as(u64, 29), pipe(view, .{operation}));
    try std.testing.expectEqual(@as(u32, 106), Helpers.trace[0]);
}

test "operator reuse copies scalar/struct seeds but shares pointer-backed state" {
    const Stats = struct {
        total: u64,
        count: usize,
        fn update(self: @This(), value: u32) @This() {
            return .{ .total = self.total + value, .count = self.count + 1 };
        }
        fn updateShared(self: *@This(), value: u32) *@This() {
            self.* = update(self.*, value);
            return self;
        }
    };
    const values = [_]u32{ 2, 4 };
    var seed = Stats{ .total = 10, .count = 3 };
    const operation = fold(seed, Stats.update);
    const copy = operation;
    seed.total = 99;
    const expected = Stats{ .total = 16, .count = 5 };
    try std.testing.expectEqual(expected, pipe(&values, .{operation}));
    try std.testing.expectEqual(expected, pipe(&values, .{copy}));
    const shared = fold(&seed, Stats.updateShared);
    try std.testing.expect(pipe(&values, .{shared}) == &seed);
    try std.testing.expect(pipe(&values, .{shared}) == &seed);
    try std.testing.expectEqual(Stats{ .total = 111, .count = 7 }, seed);
}

test "error elements and boxed error state remain data under both executors" {
    const Value = error{Missing}!u32;
    const State = struct { total: u64 = 0, missing: usize = 0, last: ?error{Missing} = null };
    const Helpers = struct {
        fn accumulate(state: State, value: Value) State {
            const item = value catch |err| return .{
                .total = state.total,
                .missing = state.missing + 1,
                .last = err,
            };
            var result = state;
            result.total += item;
            return result;
        }
        fn checked(state: State, value: Value) error{}!State {
            return accumulate(state, value);
        }
        fn optional(total: u64, value: ?u32) u64 {
            return total + (value orelse 10);
        }
        fn nested(state: ?Value, _: u32) ?Value {
            return state;
        }
    };
    const values = [_]Value{ 2, error.Missing, 3 };
    const expected = State{ .total = 5, .missing = 1, .last = error.Missing };
    try std.testing.expectEqual(expected, pipe(&values, .{fold(State{}, Helpers.accumulate)}));
    try std.testing.expectEqual(expected, try tryPipe(&values, .{fold(State{}, Helpers.accumulate)}));
    try std.testing.expectEqual(expected, try tryPipe(&values, .{tryFold(State{}, Helpers.checked)}));
    const optionals = [_]?u32{ null, 2 };
    try std.testing.expectEqual(@as(u64, 12), pipe(&optionals, .{fold(0, Helpers.optional)}));
    const source = [_]u32{1};
    const nested = pipe(&source, .{fold(@as(?Value, @as(Value, error.Missing)), Helpers.nested)});
    try std.testing.expect(nested != null);
    try std.testing.expectError(error.Missing, nested.?);
    const nested_try = try tryPipe(&source, .{fold(@as(?Value, @as(Value, error.Missing)), Helpers.nested)});
    try std.testing.expectError(error.Missing, nested_try.?);
}

test "zero-bit accumulator state and a singleton source work under both folds" {
    const Helpers = struct {
        var observed: u32 = 0;
        fn observe(_: void, value: u32) void {
            observed = value;
        }
        fn checked(state: void, value: u32) error{}!void {
            observe(state, value);
        }
    };
    const source = [_]u32{7};
    Helpers.observed = 0;
    const result = pipe(&source, .{fold({}, Helpers.observe)});
    try std.testing.expectEqual(void, @TypeOf(result));
    try std.testing.expectEqual(@as(u32, 7), Helpers.observed);
    Helpers.observed = 0;
    try tryPipe(&source, .{tryFold({}, Helpers.checked)});
    try std.testing.expectEqual(@as(u32, 7), Helpers.observed);
}

test "tryFold stops first/middle/last failures under either executor without an extra probe" {
    const Helpers = struct {
        var predicates: usize = 0;
        var transforms: usize = 0;
        var reducers: usize = 0;
        fn accept(_: u32) bool {
            predicates += 1;
            return true;
        }
        fn transform(value: u32) u32 {
            transforms += 1;
            return value;
        }
        fn accumulate(total: u64, value: u32) error{Zero}!u64 {
            reducers += 1;
            return checkedAdd(total, value);
        }
        fn recover(value: error{Zero}!u64) u64 {
            return value catch 99;
        }
        fn record(destination: *u64, value: u64) void {
            destination.* = value;
        }
    };
    for (0..3) |failure_index| {
        var values = [_]u32{ 1, 2, 3 };
        values[failure_index] = 0;
        inline for (.{ false, true }) |fail_fast| {
            Helpers.predicates = 0;
            Helpers.transforms = 0;
            Helpers.reducers = 0;
            var recorded: u64 = 7;
            const view = pipe(&values, .{ filter(Helpers.accept), each(Helpers.transform) });
            if (fail_fast) {
                const result = tryPipe(view, .{
                    tryFold(0, Helpers.accumulate),
                    tapWith(&recorded, Helpers.record),
                });
                try std.testing.expectError(error.Zero, result);
                try std.testing.expectEqual(@as(u64, 7), recorded);
            } else {
                const result = pipe(view, .{
                    tryFold(0, Helpers.accumulate),
                    map(Helpers.recover),
                    tapWith(&recorded, Helpers.record),
                });
                try std.testing.expectEqual(@as(u64, 99), result);
                try std.testing.expectEqual(@as(u64, 99), recorded);
            }
            try std.testing.expectEqual(failure_index + 1, Helpers.predicates);
            try std.testing.expectEqual(failure_index + 1, Helpers.transforms);
            try std.testing.expectEqual(failure_index + 1, Helpers.reducers);
            // The view remains reusable even after a failed consumption.
            Helpers.predicates = 0;
            Helpers.transforms = 0;
            try std.testing.expectEqual(@as(u64, 6 - (failure_index + 1)), pipe(view, .{fold(0, add)}));
            try std.testing.expectEqual(@as(usize, 3), Helpers.predicates);
        }
    }
}

test "tryFold retains partial effects and leaves resource cleanup with the caller" {
    const State = struct {
        buffer: []u8,
        written: usize = 0,
        fn append(self: @This(), value: u8) error{Zero}!@This() {
            if (value == 0) return error.Zero;
            self.buffer[self.written] = value;
            return .{ .buffer = self.buffer, .written = self.written + 1 };
        }
    };
    const owned = try std.testing.allocator.alloc(u8, 3);
    defer std.testing.allocator.free(owned);
    @memset(owned, 99);
    const source = [_]u8{ 1, 0, 3 };
    try std.testing.expectError(error.Zero, tryPipe(&source, .{
        tryFold(State{ .buffer = owned }, State.append),
    }));
    try std.testing.expectEqualSlices(u8, &.{ 1, 99, 99 }, owned);
}

test "tryFold error sets merge with input and later stage errors" {
    const Helpers = struct {
        fn finish(value: u64) error{TooLarge}!u64 {
            if (value > 5) return error.TooLarge;
            return value;
        }
    };
    const source = [_]u32{ 1, 2, 3 };
    const input: error{Initial}![]const u32 = &source;
    const result = tryPipe(input, .{ tryFold(0, checkedAdd), map(Helpers.finish) });
    try std.testing.expectEqual(error{ Initial, Zero, TooLarge }!u64, @TypeOf(result));
    try std.testing.expectError(error.TooLarge, result);
    try std.testing.expectEqual(@as(u64, 5), try tryPipe(source[0..2], .{ tryFold(2, checkedAdd), map(Helpers.finish) }));
}
