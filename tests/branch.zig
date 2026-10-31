const std = @import("std");
const zrx = @import("zrx");
const cases_example = @import("cases_example");
const branch = zrx.branch;
const when = zrx.when;
const otherwise = zrx.otherwise;
const pipe = zrx.pipe;
const each = zrx.each;
const take = zrx.take;
const filter = zrx.filter;
const batchThen = zrx.batchThen;
const forEach = zrx.forEach;
const collectThen = zrx.collectThen;
const fromSlice = zrx.fromSlice;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn odd(value: u16) bool {
    return value % 2 == 1;
}
fn double(value: u16) u16 {
    return value * 2;
}
fn triple(value: u16) u16 {
    return value * 3;
}
const Output = struct { values: *std.ArrayList(u16) };
const Other = struct { values: *std.ArrayList(u16) };
fn append(output: Output, value: u16) !void {
    try output.values.append(allocator, value);
}
fn appendOther(output: Other, value: u16) !void {
    try output.values.append(allocator, value);
}
fn copy(output: Output, items: []const u16) !void {
    try output.values.appendSlice(allocator, items);
}

test "value branches normalize single and tuple pipelines and merge outputs" {
    const input = [_]u16{ 1, 2, 3, 4, 5, 6 };
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    const routed = pipe(fromSlice(&input), .{branch(.{
        when(odd, each(double)),
        otherwise(.{each(triple)}),
    })});
    try run(.{ allocator, io, Output{ .values = &output } }, .{pipe(&routed, .{collectThen(copy)})});
    std.mem.sort(u16, output.items, {}, std.sort.asc(u16));
    try std.testing.expectEqualSlices(u16, &.{ 2, 6, 6, 10, 12, 18 }, output.items);
}

test "all terminal cases form one terminal flow with persistent substreams" {
    const input = [_]u16{ 1, 2, 3, 4, 5, 6 };
    var odds: std.ArrayList(u16) = .empty;
    defer odds.deinit(allocator);
    var evens: std.ArrayList(u16) = .empty;
    defer evens.deinit(allocator);
    const effect = pipe(fromSlice(&input), .{branch(.{
        when(odd, .{ take(1), forEach(append) }),
        otherwise(forEach(appendOther)),
    })});
    try run(.{ allocator, io, Output{ .values = &odds }, Other{ .values = &evens } }, .{effect});
    try std.testing.expectEqualSlices(u16, &.{1}, odds.items);
    try std.testing.expectEqualSlices(u16, &.{ 2, 4, 6 }, evens.items);
}

test "unmatched input is dropped and predicates short circuit first match" {
    const Checks = struct {
        var later: std.atomic.Value(usize) = .init(0);
        fn laterPredicate(_: u16) bool {
            _ = later.fetchAdd(1, .monotonic);
            return true;
        }
    };
    Checks.later.store(0, .monotonic);
    const input = [_]u16{ 1, 3, 5 };
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    const routed = pipe(fromSlice(&input), .{branch(.{
        when(odd, each(double)),
        when(Checks.laterPredicate, each(triple)),
    })});
    try run(.{ allocator, io, Output{ .values = &output } }, .{pipe(&routed, .{collectThen(copy)})});
    try std.testing.expectEqualSlices(u16, &.{ 2, 6, 10 }, output.items);
    try std.testing.expectEqual(@as(usize, 0), Checks.later.load(.monotonic));
    output.clearRetainingCapacity();
    const evens = [_]u16{ 2, 4 };
    const dropped = pipe(fromSlice(&evens), .{branch(.{when(odd, each(double))})});
    try run(.{ allocator, io, Output{ .values = &output } }, .{pipe(&dropped, .{collectThen(copy)})});
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "source failure reaches active and idle cases" {
    const Producer = struct {
        fn produce(output: *zrx.Emitter(u16)) !void {
            try output.push(1);
            return error.SourceFailed;
        }
    };
    const input = zrx.Stream(u16).fromProducer(1, Producer.produce);
    const routed = pipe(&input, .{branch(.{
        when(odd, each(double)),
        otherwise(each(triple)),
    })});
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    try std.testing.expectError(error.SourceFailed, run(.{ allocator, io, Output{ .values = &output } }, .{pipe(&routed, .{collectThen(copy)})}));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "all early-completing cases leave a cold producer unstarted" {
    const Producer = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn produce(output: *zrx.Emitter(u16)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            var value: u16 = 0;
            while (true) : (value +%= 1) try output.push(value);
        }
    };
    Producer.calls.store(0, .monotonic);
    const input = zrx.Stream(u16).fromProducer(1, Producer.produce);
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    const effect = pipe(&input, .{branch(.{
        when(odd, .{ take(0), forEach(append) }),
        otherwise(.{ take(0), forEach(append) }),
    })});
    try run(.{ allocator, io, Output{ .values = &output } }, .{effect});
    try std.testing.expectEqual(@as(usize, 0), Producer.calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

const LeftCount = struct { value: *usize };
const RightCount = struct { value: *usize };
fn countItems(count: LeftCount, items: []const u16) void {
    count.value.* += items.len;
}
fn countOtherItems(count: RightCount, items: []const u16) void {
    count.value.* += items.len;
}

fn allocationFixture(a: std.mem.Allocator) !void {
    const input = [_]u16{ 1, 2, 3, 4, 5, 6 };
    var counts = [_]usize{ 0, 0 };
    errdefer std.debug.assert(counts[0] == 0 and counts[1] == 0);
    const effect = pipe(fromSlice(&input), .{branch(.{
        when(odd, batchThen(2, countItems)),
        otherwise(.{batchThen(2, countOtherItems)}),
    })});
    try run(.{ a, io, LeftCount{ .value = &counts[0] }, RightCount{ .value = &counts[1] } }, .{effect});
    try std.testing.expectEqualSlices(usize, &.{ 3, 3 }, &counts);
}

test "preparation failures free partial outlets plans and terminal buffers" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFixture, .{});
}

test "empty input invokes no effects and filtering is case-local" {
    const input = [_]u16{ 1, 2, 3, 4 };
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    const routed = pipe(fromSlice(&input), .{branch(.{
        when(odd, .{ filter(odd), each(double) }),
        otherwise(.{ filter(odd), each(triple) }),
    })});
    try run(.{ allocator, io, Output{ .values = &output } }, .{pipe(&routed, .{collectThen(copy)})});
    try std.testing.expectEqualSlices(u16, &.{ 2, 6 }, output.items);
    output.clearRetainingCapacity();
    const empty: []const u16 = &.{};
    const effect = pipe(fromSlice(empty), .{branch(.{
        when(odd, forEach(append)),
        otherwise(forEach(append)),
    })});
    try run(.{ allocator, io, Output{ .values = &output } }, .{effect});
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

fn ignore(_: u16) void {}

test "case worker startup failure opens no producer gate" {
    const Producer = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn produce(output: *zrx.Emitter(u16)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(1);
        }
    };
    Producer.calls.store(0, .monotonic);
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2) });
    defer backend.deinit();
    const input = zrx.Stream(u16).fromProducer(1, Producer.produce);
    const effect = pipe(&input, .{branch(.{
        when(odd, forEach(ignore)),
        otherwise(forEach(ignore)),
    })});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(.{ allocator, backend.io() }, .{effect}));
    try std.testing.expectEqual(@as(usize, 0), Producer.calls.load(.monotonic));
}

test "terminal case failures fail the whole branch without rollback" {
    const Effects = struct {
        fn fail(_: u16) error{CaseFailed}!void {
            return error.CaseFailed;
        }
    };
    const input = [_]u16{ 1, 2, 3, 4 };
    const effect = pipe(fromSlice(&input), .{branch(.{
        when(odd, forEach(Effects.fail)),
        otherwise(forEach(ignore)),
    })});
    try std.testing.expectError(error.CaseFailed, run(.{ allocator, io }, .{effect}));
}

test "canceling terminal branching joins an idle producer and all case tasks" {
    const Producer = struct {
        var waiting: std.Io.Event = .unset;
        var block: std.Io.Event = .unset;
        fn produce(_: *zrx.Emitter(u16)) !void {
            waiting.set(io);
            try block.wait(io);
        }
    };
    Producer.waiting.reset();
    Producer.block.reset();
    const Runner = struct {
        fn execute() !void {
            const input = zrx.Stream(u16).fromProducer(1, Producer.produce);
            const effect = pipe(&input, .{branch(.{
                when(odd, forEach(ignore)),
                otherwise(forEach(ignore)),
            })});
            try run(.{ allocator, io }, .{effect});
        }
    };
    var task = try io.concurrent(Runner.execute, .{});
    defer task.cancel(io) catch {};
    try Producer.waiting.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.Canceled, task.cancel(io));
}

test "terminal example execute uses named cases and explicit capabilities" {
    const input = [_]i32{ -2, -1, 0, 1, 2 };
    const counts = try cases_example.execute(allocator, io, &input);
    try std.testing.expectEqual(@as(usize, 2), counts.negative);
    try std.testing.expectEqual(@as(usize, 3), counts.nonnegative);
}

const Settings = struct { threshold: u16, multiplier: u16 };
fn above(settings: Settings, value: u16) bool {
    return value > settings.threshold;
}
fn multiply(settings: Settings, value: u16) u16 {
    return value * settings.multiplier;
}
test "branch predicates and case callbacks inject services without consuming the item suffix" {
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(allocator);
    const routed = pipe(fromSlice(&[_]u16{ 1, 2, 3, 4 }), .{branch(.{
        when(above, each(multiply)),
        otherwise(each(double)),
    })});
    try run(.{ allocator, io, Settings{ .threshold = 2, .multiplier = 3 }, @as(u16, 999), Output{ .values = &output } }, .{
        pipe(&routed, .{collectThen(copy)}),
    });
    std.mem.sort(u16, output.items, {}, std.sort.asc(u16));
    try std.testing.expectEqualSlices(u16, &.{ 2, 4, 9, 12 }, output.items);
}

fn add(state: u64, item: u16) u64 {
    return state + item;
}
fn expectRecurrences(items: []const u64) !void {
    try std.testing.expectEqual(@as(usize, 6), items.len);
    // Unspecified cross-case interleaving, but each recurrence retains order.
    const expected = [_][]const u64{ &.{ 1, 4, 9 }, &.{ 102, 106, 112 } };
    var positions = [_]usize{ 0, 0 };
    for (items) |item| {
        const lane: usize = if (item < 100) 0 else 1;
        try std.testing.expect(positions[lane] < 3);
        try std.testing.expectEqual(expected[lane][positions[lane]], item);
        positions[lane] += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 3, 3 }, &positions);
}
test "stateful cases receive persistent substreams rather than singleton attempts" {
    const routed = pipe(fromSlice(&[_]u16{ 1, 2, 3, 4, 5, 6 }), .{branch(.{
        when(odd, zrx.scan(@as(u64, 0), add)),
        otherwise(zrx.scan(@as(u64, 100), add)),
    })});
    try run(.{ allocator, io }, .{pipe(&routed, .{collectThen(expectRecurrences)})});
}

const Lifetime = struct { alive: bool = false, released: bool = false };
const Service = struct { lifetime: *Lifetime };
fn acquire(lifetime: *Lifetime, _: void) Service {
    lifetime.alive = true;
    return .{ .lifetime = lifetime };
}
fn release(service: Service) void {
    service.lifetime.alive = false;
    service.lifetime.released = true;
}
fn checkService(service: Service, _: u16) !void {
    try std.testing.expect(service.lifetime.alive and !service.lifetime.released);
}
test "terminal case services acquire before execution and release after case users join" {
    var lifetime: Lifetime = .{};
    const effect = pipe(fromSlice(&[_]u16{ 1, 2, 3, 4 }), .{branch(.{
        when(odd, forEach(checkService)),
        otherwise(forEach(checkService)),
    })});
    try run(.{ allocator, io, &lifetime, zrx.resource({}, acquire, release) }, .{effect});
    try std.testing.expect(lifetime.released and !lifetime.alive);
}

test "case worker startup failure precedes selected resource acquisition" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2), .async_limit = .nothing });
    defer backend.deinit();
    var lifetime: Lifetime = .{};
    const effect = pipe(fromSlice(&[_]u16{ 1, 2 }), .{branch(.{
        when(odd, forEach(checkService)),
        otherwise(forEach(checkService)),
    })});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(.{
        allocator, backend.io(), &lifetime, zrx.resource({}, acquire, release),
    }, .{effect}));
    try std.testing.expect(!lifetime.alive and !lifetime.released);
}
