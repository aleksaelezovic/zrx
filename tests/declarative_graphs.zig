const std = @import("std");
const zrx = @import("zrx");
const io_example = @import("io_example");
const pipe = zrx.pipe;
const run = zrx.run;
const fromSlice = zrx.fromSlice;
const each = zrx.each;
const filter = zrx.filter;
const collectThen = zrx.collectThen;
const fold = zrx.fold;
const forEach = zrx.forEach;
const take = zrx.take;
const hold = zrx.hold;
const map = zrx.map;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const merge = zrx.merge;
const allocator = std.testing.allocator;
const io = std.testing.io;

const State = struct {
    calls: usize = 0,
    evaluated: usize = 0,
    items: [64]u32 = undefined,
    len: usize = 0,
    sum: u64 = 0,
};
const Left = struct { value: *State };
const Right = struct { value: *State };
fn produce(state: *State, output: *zrx.Emitter(u32)) !void {
    state.calls += 1;
    for (0..8) |i| try output.push(@intCast(i));
}
fn double(state: *State, value: u32) u32 {
    state.evaluated += 1;
    return value * 2;
}
fn keep(value: u32) bool {
    return value % 4 == 0;
}
fn copyLeft(left: Left, items: []const u32) void {
    @memcpy(left.value.items[0..items.len], items);
    left.value.len = items.len;
}
fn copyRight(right: Right, items: []const u32) void {
    @memcpy(right.value.items[0..items.len], items);
    right.value.len = items.len;
}

test "producer chain fuses into terminal with only two concurrent slots" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2), .async_limit = .nothing });
    defer backend.deinit();
    var state: State = .{};
    var output: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const flow = pipe(&source, .{ each(double), filter(keep), collectThen(copyLeft) });
    try run(.{ allocator, backend.io(), &state, Left{ .value = &output } }, .{flow});
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 8), state.evaluated);
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 8, 12 }, output.items[0..output.len]);
}

fn increment(value: u32) u32 {
    return value + 1;
}
test "exclusive named stages introduce no forwarding workers" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2), .async_limit = .nothing });
    defer backend.deinit();
    var state: State = .{};
    var output: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const mapped = pipe(&source, .{each(double)});
    const filtered = pipe(&mapped, .{filter(keep)});
    const named = pipe(&filtered, .{each(increment)});
    try run(.{ allocator, backend.io(), &state, Left{ .value = &output } }, .{
        pipe(&named, .{collectThen(copyLeft)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 1, 5, 9, 13 }, output.items[0..output.len]);
    try std.testing.expectEqual(@as(usize, 8), state.evaluated);
}

test "exclusive named ancestors fuse before one shared derived boundary" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(4), .async_limit = .nothing });
    defer backend.deinit();
    var state: State = .{};
    var left: State = .{};
    var right: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const mapped = pipe(&source, .{each(double)});
    const filtered = pipe(&mapped, .{filter(keep)});
    const shared = pipe(&filtered, .{each(increment)});
    try run(.{ allocator, backend.io(), &state, Left{ .value = &left }, Right{ .value = &right } }, .{
        pipe(&shared, .{collectThen(copyLeft)}),
        pipe(&shared, .{collectThen(copyRight)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 1, 5, 9, 13 }, left.items[0..left.len]);
    try std.testing.expectEqualSlices(u32, left.items[0..left.len], right.items[0..right.len]);
    try std.testing.expectEqual(@as(usize, 8), state.evaluated);
}

test "shared derived prefix retires one edge while its sibling drains once" {
    var state: State = .{};
    var short: State = .{};
    var whole: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const shared = pipe(&source, .{each(double)});
    try run(.{ allocator, io, &state, Left{ .value = &short }, Right{ .value = &whole } }, .{
        pipe(&shared, .{ take(2), collectThen(copyLeft) }),
        pipe(&shared, .{collectThen(copyRight)}),
    });
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 8), state.evaluated);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, short.items[0..short.len]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6, 8, 10, 12, 14 }, whole.items[0..whole.len]);
}

const Offset = struct { value: u32 };
fn addOffset(offset: Offset, value: u32) u32 {
    return value + offset.value;
}
test "signal maps receive services for initial and replacement computations" {
    var saved: State = .{};
    const updates = fromSlice(&[_]u32{ 1, 2, 3 });
    const signal = pipe(&updates, .{ hold(@as(u32, 5)), map(addOffset) });
    try run(.{ allocator, io, Offset{ .value = 2 }, Left{ .value = &saved } }, .{
        pipe(values(&signal), .{collectThen(copyLeft)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 7, 3, 4, 5 }, saved.items[0..saved.len]);
}

fn sampleSum(state: *State, pair: struct { u32, u32 }) void {
    state.sum += pair[0] + pair[1];
}
test "sampling uses run-owned state with no observation terminal" {
    var state: State = .{};
    const signal = pipe(fromSlice(&[_]u32{}), .{hold(@as(u32, 9))});
    try run(.{ allocator, io, &state }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3 }), .{ withLatestFrom(&signal), forEach(sampleSum) }),
    });
    try std.testing.expectEqual(@as(u64, 33), state.sum);
}

fn add(sum: u64, value: u32) u64 {
    return sum + value;
}
fn saveSum(state: *State, value: u64) void {
    state.sum = value;
}
test "merge feeds a deferred reduction and terminal effect" {
    var state: State = .{};
    const first = fromSlice(&[_]u32{ 1, 2 });
    const second = fromSlice(&[_]u32{3});
    try run(.{ allocator, io, &state }, .{
        pipe(merge(.{ &first, &second }), .{ fold(@as(u64, 0), add), forEach(saveSum) }),
    });
    try std.testing.expectEqual(@as(u64, 6), state.sum);
}

test "new API runs actual path-owned file graph and flushes before success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = "one\ntwo\n" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const input = try std.fs.path.join(allocator, &.{ directory, "input" });
    defer allocator.free(input);
    const output = try std.fs.path.join(allocator, &.{ directory, "output" });
    defer allocator.free(output);
    try run(.{ allocator, io }, .{io_example.program(input, output)});
    const bytes = try tmp.dir.readFileAlloc(io, "output", allocator, .limited(1024));
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("one\ntwo\n", bytes);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var state: State = .{};
    var output: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const first = pipe(&source, .{each(double)});
    const second = pipe(&first, .{filter(keep)});
    // Only one consumer allocates after activation. The non-thread-safe
    // FailingAllocator is never accessed concurrently by multiple allocating tasks.
    try run(.{ gpa, io, &state, Left{ .value = &output } }, .{
        pipe(&second, .{collectThen(copyLeft)}),
    });
}
test "allocation failures unwind alias planning lowering transport and collection" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}

test "resource acquisition waits for gated startup and resources survive failed activation" {
    const Counter = struct { opened: usize = 0, closed: usize = 0, produced: usize = 0 };
    const Owned = struct { counter: *Counter };
    const Helpers = struct {
        fn acquire(counter: *Counter, _: void) Owned {
            counter.opened += 1;
            return .{ .counter = counter };
        }
        fn release(owned: Owned) void {
            owned.counter.closed += 1;
        }
        fn produceOwned(owned: Owned, output: *zrx.Emitter(u32)) !void {
            owned.counter.produced += 1;
            try output.push(1);
        }
        fn ignore(_: u32) void {}
    };
    for (0..2) |limit| {
        var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(limit), .async_limit = .nothing });
        defer backend.deinit();
        var counter: Counter = .{};
        const source = zrx.Stream(u32).fromProducer(1, Helpers.produceOwned);
        try std.testing.expectError(error.ConcurrencyUnavailable, run(.{
            allocator, backend.io(), &counter, zrx.resource({}, Helpers.acquire, Helpers.release),
        }, .{pipe(&source, .{forEach(Helpers.ignore)})}));
        try std.testing.expectEqual(limit, counter.opened);
        try std.testing.expectEqual(counter.opened, counter.closed);
        try std.testing.expectEqual(@as(usize, 0), counter.produced);
    }
}

test "owned services release after canceled producer and peer callback exit" {
    const Probe = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        producer_stopped: std.atomic.Value(bool) = .init(false),
        callback_stopped: std.atomic.Value(bool) = .init(false),
        released: bool = false,
        early: bool = false,
    };
    const Owned = struct { probe: *Probe };
    const Helpers = struct {
        fn acquire(probe: *Probe, _: void) Owned {
            return .{ .probe = probe };
        }
        fn release(owned: Owned) void {
            owned.probe.early = !owned.probe.producer_stopped.load(.acquire) or !owned.probe.callback_stopped.load(.acquire);
            owned.probe.released = true;
        }
        fn source(owned: Owned, output: *zrx.Emitter(u32)) !void {
            defer owned.probe.producer_stopped.store(true, .release);
            try output.push(1);
            try owned.probe.gate.wait(output.io);
        }
        fn block(owned: Owned, _: u32) !void {
            defer owned.probe.callback_stopped.store(true, .release);
            owned.probe.entered.set(io);
            try owned.probe.gate.wait(io);
        }
        fn fail(owned: Owned, _: u32) !void {
            try owned.probe.entered.wait(io);
            return error.CallbackFailed;
        }
        fn execute(probe: *Probe) !void {
            defer probe.done.set(io);
            const source_decl = zrx.Stream(u32).fromProducer(1, source);
            try run(.{ allocator, io, probe, zrx.resource({}, acquire, release) }, .{
                pipe(&source_decl, .{forEach(block)}),
                pipe(&source_decl, .{forEach(fail)}),
            });
        }
    };
    var probe: Probe = .{};
    var task = try io.concurrent(Helpers.execute, .{&probe});
    defer task.cancel(io) catch {};
    try probe.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.CallbackFailed, task.await(io));
    try std.testing.expect(probe.released and !probe.early);
}

test "take zero is cold and successful end flushes batches and retained suffixes" {
    const Helpers = struct {
        fn batch(left: Left, items: []const u32) void {
            for (items) |value| {
                left.value.items[left.value.len] = value;
                left.value.len += 1;
            }
        }
    };
    var state: State = .{};
    var zero: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, produce);
    try run(.{ allocator, io, &state, Left{ .value = &zero } }, .{
        pipe(&source, .{ take(0), collectThen(copyLeft) }),
    });
    try std.testing.expectEqual(@as(usize, 0), state.calls);
    try std.testing.expectEqual(@as(usize, 0), zero.len);
    var suffix: State = .{};
    try run(.{ allocator, io, Left{ .value = &suffix } }, .{
        pipe(fromSlice(&[_]u32{ 1, 2, 3, 4, 5 }), .{ zrx.takeLast(3), zrx.batchThen(2, Helpers.batch) }),
    });
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, suffix.items[0..suffix.len]);
}

test "signal map error union results remain state data rather than stream operation failures" {
    const E = error{Bad};
    const Helpers = struct {
        fn derive(value: u32) E!u64 {
            return if (value == 0) error.Bad else @as(u64, value) * 2;
        }
        fn inspect(state: *State, items: []const (E!u64)) !void {
            try std.testing.expectEqual(@as(usize, 2), items.len);
            try std.testing.expectError(error.Bad, items[0]);
            state.sum = try items[1];
        }
    };
    var state: State = .{};
    const source = fromSlice(&[_]u32{1});
    const current = pipe(&source, .{ hold(@as(u32, 0)), map(Helpers.derive) });
    try run(.{ allocator, io, &state }, .{
        pipe(values(&current), .{collectThen(Helpers.inspect)}),
    });
    try std.testing.expectEqual(@as(u64, 2), state.sum);
}
