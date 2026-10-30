const std = @import("std");
// Internal transport/adapter coverage, compiled against runtime_test_api.zig.
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const each = zrx.each;
const filter = zrx.filter;
const collectInto = zrx.collectInto;
const collectAlloc = zrx.collectAlloc;
const fromIterator = zrx.fromIterator;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const Stream = zrx.Stream;
const readFrom = zrx.readFrom;
const io = std.testing.io;

const Counter = struct {
    value: u32 = 0,
    calls: usize = 0,

    pub fn next(self: *@This()) ?u32 {
        self.calls += 1;
        if (self.value == 3) return null;
        self.value += 1;
        return self.value;
    }
};

const Fallible = struct {
    value: u32 = 0,

    pub fn next(self: *@This()) error{Broken}!?u32 {
        self.value += 1;
        if (self.value == 3) return error.Broken;
        return self.value;
    }
};

fn double(value: u32) u32 {
    return value * 2;
}

fn increment(value: u32) u64 {
    return value + 1;
}

fn even(value: u32) bool {
    return value % 2 == 0;
}

fn record(sum: *u64, value: u32) void {
    sum.* += value;
}

test "iterator production and transforms start only on consumption" {
    var source: Counter = .{};
    const view = pipe(fromIterator(&source), .{ filter(even), each(.{ double, increment }) });
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    var input = view.iterator();
    try std.testing.expectEqual(@as(?u64, 5), input.next());
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    try std.testing.expectEqual(@as(?u64, null), input.next());
}

test "borrowed consuming iterator views share position rather than rewind" {
    var source: Counter = .{};
    const view = fromIterator(&source);
    var first = view.iterator();
    var second = view.iterator();
    try std.testing.expectEqual(@as(?u32, 1), first.next());
    try std.testing.expectEqual(@as(?u32, 2), second.next());
    try std.testing.expectEqual(@as(?u32, 3), first.next());
    try std.testing.expectEqual(@as(?u32, null), second.next());
}

test "fallible cursors propagate transport errors through filter each and collect" {
    var source: Fallible = .{};
    var output: [3]u64 = undefined;
    const result = pipe(fromIterator(&source), .{
        filter(even),
        each(.{ double, increment }),
        collectInto(&output),
    });
    try std.testing.expectEqual(error{ Broken, NoSpaceLeft }![]u64, @TypeOf(result));
    try std.testing.expectError(error.Broken, result);
    try std.testing.expectEqual(@as(u64, 5), output[0]);
}

test "grouped and separate each forms match on fallible inputs" {
    var first: Fallible = .{};
    var second: Fallible = .{};
    var a = pipe(fromIterator(&first), .{each(.{ double, increment })}).iterator();
    var b = pipe(fromIterator(&second), .{ each(double), each(increment) }).iterator();
    try std.testing.expectEqual(try a.next(), try b.next());
    try std.testing.expectEqual(try a.next(), try b.next());
    try std.testing.expectError(error.Broken, a.next());
    try std.testing.expectError(error.Broken, b.next());
}

test "owned stream pushes without consuming then drains after repeated close" {
    var source = try Stream(u32).init(std.testing.allocator, io, 2);
    defer source.deinit();
    const view = pipe(&source, .{each(double)});
    const small: u8 = 1;
    try source.push(small);
    try source.push(2);
    source.close();
    source.close();
    try std.testing.expectError(error.Closed, source.push(3));
    var output: [2]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, try pipe(view, .{collectInto(&output)}));
    var input = view.iterator();
    try std.testing.expectEqual(@as(?u32, null), try input.next());
}

test "standard queue input is borrowed and never implicitly closed" {
    var storage: [2]u32 = undefined;
    var source: std.Io.Queue(u32) = .init(&storage);
    defer source.close(io);
    try source.putOne(io, 3);
    var input = readFrom(io, &source).iterator();
    try std.testing.expectEqual(@as(?u32, 3), try input.next());
    try source.putOne(io, 4);
    try std.testing.expectEqual(@as(u32, 4), try source.getOne(io));
}

fn receive(source: *Stream(u32)) !?u32 {
    var input = source.iterator();
    return input.next();
}

fn send(source: *Stream(u32), value: u32) !void {
    try source.push(value);
}

test "empty consumer and full producer progress using explicit concurrent tasks" {
    var source = try Stream(u32).init(std.testing.allocator, io, 1);
    defer source.deinit();
    defer source.close();
    var consumer = try io.concurrent(receive, .{&source});
    defer _ = consumer.cancel(io) catch {};
    try source.push(10);
    try std.testing.expectEqual(@as(?u32, 10), try consumer.await(io));

    try source.push(20);
    var producer = try io.concurrent(send, .{ &source, 30 });
    defer producer.cancel(io) catch {};
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 20), try input.next());
    try producer.await(io);
    try std.testing.expectEqual(@as(?u32, 30), try input.next());
}

test "zero capacity is a rendezvous channel" {
    var source = try Stream(u32).init(std.testing.allocator, io, 0);
    defer source.deinit();
    defer source.close();
    var producer = try io.concurrent(send, .{ &source, 7 });
    defer producer.cancel(io) catch {};
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try input.next());
    try producer.await(io);
}

test "cancellation is an error not end and does not close the stream" {
    var source = try Stream(u32).init(std.testing.allocator, io, 1);
    defer source.deinit();
    defer source.close();
    var consumer = try io.concurrent(receive, .{&source});
    try std.testing.expectError(error.Canceled, consumer.cancel(io));
    try source.push(9);
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 9), try input.next());

    try source.push(10);
    var producer = try io.concurrent(send, .{ &source, 11 });
    try std.testing.expectError(error.Canceled, producer.cancel(io));
    try std.testing.expectEqual(@as(?u32, 10), try input.next());
}

test "closure wakes an empty reader" {
    var source = try Stream(u32).init(std.testing.allocator, io, 1);
    defer source.deinit();
    var consumer = try io.concurrent(receive, .{&source});
    defer _ = consumer.cancel(io) catch {};
    source.close();
    try std.testing.expectEqual(@as(?u32, null), try consumer.await(io));
}

test "closure wakes a full producer while retaining accepted items" {
    var source = try Stream(u32).init(std.testing.allocator, io, 1);
    defer source.deinit();
    try source.push(1);
    var producer = try io.concurrent(send, .{ &source, 2 });
    defer producer.cancel(io) catch {};
    source.close();
    try std.testing.expectError(error.Closed, producer.await(io));
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try input.next());
    try std.testing.expectEqual(@as(?u32, null), try input.next());
}

test "stream item errors and nulls remain data through mapping and filtering" {
    const Item = error{ Bad, Canceled, Closed }!?u32;
    const Helpers = struct {
        fn same(value: Item) Item {
            return value;
        }
        fn accept(_: Item) bool {
            return true;
        }
    };
    var source = try Stream(Item).init(std.testing.allocator, io, 5);
    defer source.deinit();
    try source.push(error.Bad);
    try source.push(error.Canceled);
    try source.push(error.Closed);
    try source.push(null);
    try source.push(@as(u32, 5));
    source.close();
    var output: [5]Item = undefined;
    const result = try tryPipe(&source, .{
        each(Helpers.same),
        filter(Helpers.accept),
        collectInto(&output),
    });
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectError(error.Bad, result[0]);
    try std.testing.expectError(error.Canceled, result[1]);
    try std.testing.expectError(error.Closed, result[2]);
    try std.testing.expectEqual(@as(?u32, null), try result[3]);
    try std.testing.expectEqual(@as(?u32, 5), try result[4]);
}

fn collectLive(source: *Stream(u32), ready: *std.Io.Event) ![]u32 {
    ready.set(io);
    return pipe(source, .{ each(double), collectAlloc(std.testing.allocator) });
}

test "collection may start open and completes after close and drain" {
    var source = try Stream(u32).init(std.testing.allocator, io, 1);
    defer source.deinit();
    defer source.close();
    var ready: std.Io.Event = .unset;
    var consumer = try io.concurrent(collectLive, .{ &source, &ready });
    defer if (consumer.cancel(io)) |output| std.testing.allocator.free(output) else |_| {};
    try ready.wait(io);
    try source.push(1);
    try source.push(2);
    source.close();
    // The deferred await/cancel owns and frees the result.
    const result = try consumer.await(io);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4 }, result);
}

test "overflow consumes one extra live item without closing the source" {
    var source = try Stream(u32).init(std.testing.allocator, io, 3);
    defer source.deinit();
    defer source.close();
    try source.push(1);
    try source.push(2);
    try source.push(3);
    var output: [1]u32 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, pipe(&source, .{collectInto(&output)}));
    try std.testing.expectEqual(@as(u32, 1), output[0]);
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 3), try input.next());
}

test "forEach is terminal and forEachWith uses explicit capabilities" {
    const Helpers = struct {
        fn ignore(_: u32) void {}
        fn reject(value: u32) error{Rejected}!void {
            if (value == 2) return error.Rejected;
        }
    };
    const values = [_]u8{ 1, 2, 3 };
    const result = pipe(&values, .{forEach(Helpers.ignore)});
    try std.testing.expectEqual(void, @TypeOf(result));
    var sum: u64 = 0;
    pipe(&values, .{forEachWith(&sum, record)});
    try std.testing.expectEqual(@as(u64, 6), sum);

    var source: Counter = .{};
    try std.testing.expectError(error.Rejected, pipe(fromIterator(&source), .{forEach(Helpers.reject)}));
    try std.testing.expectEqual(@as(u32, 2), source.value);
    try pipe(fromIterator(&source), .{forEach(Helpers.reject)});
    try std.testing.expectEqual(@as(u32, 3), source.value);
}

test "forEach merges iterator and effect errors and preserves partial effects" {
    const Helpers = struct {
        fn effect(total: *u64, value: u32) error{Effect}!void {
            total.* += value;
            if (value == 2) return error.Effect;
        }
    };
    var source: Fallible = .{};
    var total: u64 = 0;
    const result = pipe(fromIterator(&source), .{forEachWith(&total, Helpers.effect)});
    try std.testing.expectEqual(error{ Broken, Effect }!void, @TypeOf(result));
    try std.testing.expectError(error.Effect, result);
    try std.testing.expectEqual(@as(u64, 3), total);
    try std.testing.expectError(error.Broken, pipe(fromIterator(&source), .{forEachWith(&total, Helpers.effect)}));
}

fn allocateScenario(allocator: std.mem.Allocator) !void {
    var source = try Stream(u32).init(allocator, io, 2);
    defer source.deinit();
    try source.push(1);
    try source.push(2);
    source.close();
    const result = try pipe(&source, .{collectAlloc(allocator)});
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, result);
}

test "allocation failures clean up stream construction and collection" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateScenario, .{});
}

test "transport failure cleans up partially allocated output" {
    var source: Fallible = .{};
    try std.testing.expectError(error.Broken, pipe(fromIterator(&source), .{collectAlloc(std.testing.allocator)}));
}

fn produceThree(output: *Stream(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
}

test "producer starts on first next not construction or pipeline declaration" {
    const Helpers = struct {
        var calls: usize = 0;
        fn produce(output: *Stream(u32)) error{ Closed, Canceled }!void {
            calls += 1;
            try produceThree(output);
        }
    };
    Helpers.calls = 0;
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    const view = pipe(&source, .{each(double)});
    var input = view.iterator();
    try std.testing.expectEqual(@as(usize, 0), Helpers.calls);
    try std.testing.expectEqual(@as(?u32, 2), try input.next());
    var output: [2]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 4, 6 }, try pipe(view, .{collectInto(&output)}));
    try std.testing.expectEqual(@as(usize, 1), Helpers.calls);
    try std.testing.expectEqual(@as(?u32, null), try input.next());
}

test "deinit and explicit close never activate a cold producer" {
    const Helpers = struct {
        var called: bool = false;
        fn produce(_: *Stream(u32)) void {
            called = true;
        }
    };
    Helpers.called = false;
    {
        var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
        defer source.deinit();
    }
    try std.testing.expect(!Helpers.called);
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    source.close();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, null), try input.next());
    try std.testing.expect(!Helpers.called);
}

test "void producer returning without items closes automatically" {
    const Helpers = struct {
        fn produce(_: *Stream(u32)) void {}
    };
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, null), try input.next());
    try std.testing.expectError(error.Closed, source.push(9));
}

test "producer error is reported after accepted values drain and stays terminal" {
    const Helpers = struct {
        fn produce(output: *Stream(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(1);
            try output.push(2);
            return error.Broken;
        }
    };
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try input.next());
    try std.testing.expectEqual(@as(?u32, 2), try input.next());
    try std.testing.expectError(error.Broken, input.next());
    try std.testing.expectError(error.Broken, input.next());
    try std.testing.expectError(error.Closed, source.push(3));
}

test "explicit early close still joins and reports the producer outcome" {
    const Helpers = struct {
        fn produce(output: *Stream(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(1);
            output.close();
            return error.Broken;
        }
    };
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try input.next());
    try std.testing.expectError(error.Broken, input.next());
}

test "owned producer cleanup cancels and joins after early consumer failure" {
    const Helpers = struct {
        var finished: bool = false;
        fn produce(output: *Stream(u32)) error{ Closed, Canceled }!void {
            defer finished = true;
            while (true) try output.push(1);
        }
        fn reject(_: u32) error{Stop}!void {
            return error.Stop;
        }
    };
    Helpers.finished = false;
    {
        var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
        defer source.deinit();
        var cursor = source.iterator();
        try std.testing.expectError(error.Stop, pipe(fromIterator(&cursor), .{forEach(Helpers.reject)}));
    }
    // Future cancellation joins before stream storage is freed.
    try std.testing.expect(Helpers.finished);
}

test "producer-backed zero capacity works without an inline startup deadlock" {
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 0, produceThree);
    defer source.deinit();
    var output: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, try pipe(&source, .{collectInto(&output)}));
}

test "competing consumers start the owned producer only once" {
    const Helpers = struct {
        var calls: usize = 0;
        fn produce(output: *Stream(u32)) error{ Closed, Canceled }!void {
            calls += 1;
            try output.push(1);
            try output.push(2);
        }
    };
    Helpers.calls = 0;
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    var first = try io.concurrent(receive, .{&source});
    defer _ = first.cancel(io) catch {};
    var second = try io.concurrent(receive, .{&source});
    defer _ = second.cancel(io) catch {};
    const a = (try first.await(io)).?;
    const b = (try second.await(io)).?;
    try std.testing.expect(a != b and a + b == 3);
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, null), try input.next());
    try std.testing.expectEqual(@as(usize, 1), Helpers.calls);
}

test "unavailable concurrency fails at first consumption without starting producer" {
    var backend: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    var source = try Stream(u32).fromProducer(std.testing.allocator, backend.io(), 1, produceThree);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectError(error.ConcurrencyUnavailable, input.next());
    try std.testing.expectError(error.ConcurrencyUnavailable, input.next());
}

fn allocateProducerScenario(allocator: std.mem.Allocator) !void {
    var source = try Stream(u32).fromProducer(allocator, io, 1, produceThree);
    defer source.deinit();
    const output = try pipe(&source, .{ each(double), collectAlloc(allocator) });
    defer allocator.free(output);
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, output);
}

test "producer allocation and early collection failure clean up all resources" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateProducerScenario, .{});
}

test "collectAlloc frees its partial output on producer failure" {
    const Helpers = struct {
        fn produce(output: *Stream(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(1);
            return error.Broken;
        }
    };
    var source = try Stream(u32).fromProducer(std.testing.allocator, io, 1, Helpers.produce);
    defer source.deinit();
    try std.testing.expectError(error.Broken, pipe(&source, .{collectAlloc(std.testing.allocator)}));
}

test "producer capability is copied at construction and used only on consumption" {
    const Config = struct { start: u32, count: u32, calls: *usize };
    const Helpers = struct {
        fn produce(config: Config, output: *Stream(u32)) error{ Closed, Canceled }!void {
            config.calls.* += 1;
            for (0..config.count) |i| try output.push(config.start + @as(u32, @intCast(i)));
        }
    };
    var calls: usize = 0;
    var config: Config = .{ .start = 10, .count = 3, .calls = &calls };
    var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, config);
    defer source.deinit();
    config.start = 99;
    try std.testing.expectEqual(@as(usize, 0), calls);
    var output: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, try pipe(&source, .{collectInto(&output)}));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "producer capability follows normal coercions and may be void" {
    const Helpers = struct {
        fn produce(value: u32, output: *Stream(u32)) error{ Closed, Canceled }!void {
            try output.push(value);
        }
        fn empty(_: void, _: *Stream(u32)) void {}
    };
    const small: u8 = 7;
    var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, small);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try input.next());
    try std.testing.expectEqual(@as(?u32, null), try input.next());

    var empty = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.empty, {});
    defer empty.deinit();
    var cursor = empty.iterator();
    try std.testing.expectEqual(@as(?u32, null), try cursor.next());
}

test "the same producer function keeps each stream capability independent" {
    const Helpers = struct {
        fn produce(value: u32, output: *Stream(u32)) error{ Closed, Canceled }!void {
            try output.push(value);
        }
    };
    var first = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, @as(u32, 1));
    defer first.deinit();
    var second = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, @as(u32, 2));
    defer second.deinit();
    var a = first.iterator();
    var b = second.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try a.next());
    try std.testing.expectEqual(@as(?u32, 2), try b.next());
}

test "unused capability storage is freed without activating its producer" {
    const Helpers = struct {
        fn produce(called: *bool, _: *Stream(u32)) void {
            called.* = true;
        }
    };
    var called = false;
    {
        var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, &called);
        defer source.deinit();
    }
    try std.testing.expect(!called);
}

test "capability-backed producer is joined before its copied capability is freed" {
    const Helpers = struct {
        fn produce(finished: *bool, output: *Stream(u32)) error{ Closed, Canceled }!void {
            defer finished.* = true;
            while (true) try output.push(1);
        }
    };
    var finished = false;
    {
        var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, &finished);
        defer source.deinit();
        var input = source.iterator();
        try std.testing.expectEqual(@as(?u32, 1), try input.next());
    }
    try std.testing.expect(finished);
}

test "capability-backed producer errors drain before propagation" {
    const Helpers = struct {
        fn produce(value: u32, output: *Stream(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(value);
            return error.Broken;
        }
    };
    var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, @as(u32, 9));
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 9), try input.next());
    try std.testing.expectError(error.Broken, input.next());
}

fn allocateCapabilityScenario(allocator: std.mem.Allocator) !void {
    const Helpers = struct {
        fn produce(value: u32, output: *Stream(u32)) error{ Closed, Canceled }!void {
            try output.push(value);
        }
    };
    var source = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.produce, @as(u32, 42));
    defer source.deinit();
    const output = try pipe(&source, .{collectAlloc(allocator)});
    defer allocator.free(output);
    try std.testing.expectEqualSlices(u32, &.{42}, output);
}

test "capability allocation and later collection failures release internal storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateCapabilityScenario, .{});
}

test "deinit cancels a producer waiting on external Io and runs resource cleanup" {
    const Waiting = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        canceled: bool = false,
        finished: bool = false,
    };
    const Helpers = struct {
        fn produce(state: *Waiting, _: *Stream(u32)) (std.mem.Allocator.Error || std.Io.Cancelable)!void {
            defer state.finished = true;
            errdefer state.entered.set(state.io);
            const resource = try state.allocator.alloc(u8, 32);
            defer state.allocator.free(resource);
            state.entered.set(state.io);
            // Never signaled: the owner must cancel this non-queue wait.
            state.gate.wait(state.io) catch |err| {
                state.canceled = true;
                return err;
            };
        }
    };
    var waiting: Waiting = .{ .allocator = std.testing.allocator, .io = io };
    {
        var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, &waiting);
        defer source.deinit();
        var consumer = try io.concurrent(receive, .{&source});
        defer _ = consumer.cancel(io) catch {};
        try waiting.entered.wait(io);
        // Finish the borrowed consumer before destroying its stream.
        try std.testing.expectError(error.Canceled, consumer.cancel(io));
    }
    // Read flags only after deinit has joined the producer.
    try std.testing.expect(waiting.canceled and waiting.finished);
}

test "external close drains accepted values then reports the producer Closed error" {
    const State = struct {
        io: std.Io,
        full: std.Io.Event = .unset,
        continue_production: std.Io.Event = .unset,
        finished: bool = false,
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Stream(u32)) error{ Closed, Canceled }!void {
            defer state.finished = true;
            try output.push(1);
            try output.push(2);
            state.full.set(state.io);
            try state.continue_production.wait(state.io);
            try output.push(3);
        }
    };
    var state: State = .{ .io = io };
    var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, &state);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try input.next());
    try state.full.wait(io);
    // Value 2 is retained and there is no consumer freeing capacity for value 3.
    source.close();
    source.close();
    state.continue_production.set(io);
    try std.testing.expectEqual(@as(?u32, 2), try input.next());
    try std.testing.expectError(error.Closed, input.next());
    try std.testing.expect(state.finished);
    try std.testing.expectError(error.Closed, input.next());
    try std.testing.expectError(error.Closed, source.push(4));
}

test "positive-capacity close rejects a pending push before publication" {
    const State = struct {
        io: std.Io,
        full: std.Io.Event = .unset,
        third_accepted: bool = false,
        finished: bool = false,
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Stream(u32)) error{ Closed, Canceled }!void {
            defer state.finished = true;
            try output.push(1);
            try output.push(2);
            state.full.set(state.io);
            try output.push(3);
            state.third_accepted = true;
        }
    };
    var state: State = .{ .io = io };
    var source = try Stream(u32).fromProducerWith(std.testing.allocator, io, 1, Helpers.produce, &state);
    defer source.deinit();
    var input = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try input.next());
    try state.full.wait(io);
    // The third push may already be pending when close wakes the producer.
    source.close();
    try std.testing.expectError(error.Closed, source.push(4));
    try std.testing.expectEqual(@as(?u32, 2), try input.next());
    try std.testing.expectError(error.Closed, input.next());
    try std.testing.expect(!state.third_accepted);
    try std.testing.expectError(error.Closed, input.next());
    try std.testing.expect(state.finished);
}

test "owned streams preserve bare error-set items in bounded and rendezvous storage" {
    const Data = error{ Canceled, Closed };
    const Helpers = struct {
        fn produce(output: *Stream(Data)) error{ Closed, Canceled }!void {
            try output.push(error.Closed);
            try output.push(error.Canceled);
        }
    };
    for ([_]usize{ 0, 1 }) |capacity| {
        var source = try Stream(Data).fromProducer(std.testing.allocator, io, capacity, Helpers.produce);
        defer source.deinit();
        var input = source.iterator();
        try std.testing.expectEqual(@as(Data, error.Closed), (try input.next()).?);
        try std.testing.expectEqual(@as(Data, error.Canceled), (try input.next()).?);
        try std.testing.expectEqual(@as(?Data, null), try input.next());
    }
}

test "standard queue adapter preserves bare error-set items as data" {
    const Data = error{ Canceled, Closed };
    var storage: [2]Data = undefined;
    var queue: std.Io.Queue(Data) = .init(&storage);
    try queue.putOne(io, error.Closed);
    try queue.putOne(io, error.Canceled);
    queue.close(io);
    var input = readFrom(io, &queue).iterator();
    try std.testing.expectEqual(@as(Data, error.Closed), (try input.next()).?);
    try std.testing.expectEqual(@as(Data, error.Canceled), (try input.next()).?);
    try std.testing.expectEqual(@as(?Data, null), try input.next());
}
