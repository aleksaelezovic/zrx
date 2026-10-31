const std = @import("std");
// Internal broadcast coverage, not a public Stream ownership contract.
const zrx = @import("zrx");
const Stream = zrx.Stream;
const tee = zrx.tee;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const collectInto = zrx.collectInto;
const io = std.testing.io;
const allocator = std.testing.allocator;

fn produce(output: *Stream(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
}

fn double(value: u32) u32 {
    return value * 2;
}

fn collect(reader: *Stream(u32).Reader, output: *[3]u32) ![]u32 {
    return pipe(reader, .{ each(double), collectInto(output) });
}

fn receive(reader: *Stream(u32).Reader) !?u32 {
    var input = reader.iterator();
    return input.next();
}

fn receiveDefault(source: *Stream(u32)) !?u32 {
    var input = source.iterator();
    return input.next();
}

fn send(source: *Stream(u32), value: u32) !void {
    try source.push(value);
}

test "capacity-one tee delivers every value without a hidden third reader" {
    var source = try Stream(u32).fromProducer(allocator, io, 1, produce);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var left_storage: [3]u32 = undefined;
    var left = try io.concurrent(collect, .{ &split.left, &left_storage });
    defer _ = left.cancel(io) catch {};
    var right_storage: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, try pipe(&split.right, .{collectInto(&right_storage)}));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, try left.await(io));
}

test "tee moves the default position including previously created cursors" {
    var source = try Stream(u32).init(allocator, io, 1);
    defer source.deinit();
    var old = source.iterator();
    var split = try tee(&source);
    defer split.deinit();
    try std.testing.expectError(error.ReaderMoved, old.next());
    try std.testing.expectError(error.ReaderMoved, tee(&source));
    var another = source.iterator();
    try std.testing.expectError(error.ReaderMoved, another.next());
    try source.push(9);
    source.close();
    var left = split.left.iterator();
    var right = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, 9), try left.next());
    try std.testing.expectEqual(@as(?u32, 9), try right.next());
}

test "tee transfers the default reader current unread prefix" {
    var source = try Stream(u32).init(allocator, io, 3);
    defer source.deinit();
    try source.push(1);
    try source.push(2);
    try source.push(3);
    source.close();
    var original = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try original.next());
    var split = try tee(&source);
    defer split.deinit();
    var a: [2]u32 = undefined;
    var b: [2]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, try pipe(&split.left, .{collectInto(&a)}));
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, try pipe(&split.right, .{collectInto(&b)}));
}

test "forking a running capacity-one producer keeps unread and future items" {
    var source = try Stream(u32).fromProducer(allocator, io, 1, produce);
    defer source.deinit();
    var original = source.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try original.next());
    var split = try tee(&source);
    defer split.deinit();
    var clone = try split.left.clone();
    defer clone.deinit();
    var a = split.left.iterator();
    var b = split.right.iterator();
    var c = clone.iterator();
    for ([_]u32{ 2, 3 }) |value| {
        try std.testing.expectEqual(@as(?u32, value), try a.next());
        try std.testing.expectEqual(@as(?u32, value), try b.next());
        try std.testing.expectEqual(@as(?u32, value), try c.next());
    }
    try std.testing.expectEqual(@as(?u32, null), try c.next());
}

test "tee and clone stay lazy and share one producer activation" {
    const Helpers = struct {
        fn source(calls: *std.atomic.Value(usize), output: *Stream(u32)) error{ Closed, Canceled }!void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(7);
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    var source = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.source, &calls);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var clone = try split.left.clone();
    defer clone.deinit();
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    var a = split.left.iterator();
    var b = split.right.iterator();
    var c = clone.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try a.next());
    try std.testing.expectEqual(@as(?u32, 7), try b.next());
    try std.testing.expectEqual(@as(?u32, 7), try c.next());
    try std.testing.expectEqual(@as(?u32, null), try a.next());
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
}

test "transformations run independently after a tee" {
    const Helpers = struct {
        var calls: usize = 0;
        fn count(value: u32) u32 {
            calls += 1;
            return value;
        }
    };
    Helpers.calls = 0;
    var source = try Stream(u32).init(allocator, io, 3);
    defer source.deinit();
    for ([_]u32{ 1, 2, 3 }) |value| try source.push(value);
    source.close();
    var split = try tee(&source);
    defer split.deinit();
    var output: [3]u32 = undefined;
    _ = try pipe(&split.left, .{ each(Helpers.count), collectInto(&output) });
    try std.testing.expectEqual(@as(usize, 3), Helpers.calls);
    _ = try pipe(&split.right, .{ each(Helpers.count), collectInto(&output) });
    try std.testing.expectEqual(@as(usize, 6), Helpers.calls);
}

test "clone starts at the unread position not the oldest retained item" {
    var source = try Stream(u32).init(allocator, io, 3);
    defer source.deinit();
    try source.push(1);
    try source.push(2);
    try source.push(3);
    source.close();
    var split = try tee(&source);
    defer split.deinit();
    var left = split.left.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try left.next());
    var clone = try split.left.clone();
    defer clone.deinit();
    var copied = clone.iterator();
    try std.testing.expectEqual(@as(?u32, 2), try copied.next());
    var right = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try right.next());
    try std.testing.expectEqual(@as(?u32, 2), try left.next());
    try std.testing.expectEqual(@as(?u32, 3), try left.next());
    try std.testing.expectEqual(@as(?u32, 3), try copied.next());
    try std.testing.expectEqual(@as(?u32, 2), try right.next());
    try std.testing.expectEqual(@as(?u32, 3), try right.next());
    try std.testing.expectEqual(@as(?u32, null), try copied.next());
}

test "reader aliases compete but a clone independently receives future values" {
    var source = try Stream(u32).init(allocator, io, 2);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var clone = try split.left.clone();
    defer clone.deinit();
    try source.push(4);
    try source.push(5);
    source.close();
    var first = split.left.iterator();
    var alias = split.left.iterator();
    var copied = clone.iterator();
    try std.testing.expectEqual(@as(?u32, 4), try first.next());
    try std.testing.expectEqual(@as(?u32, 5), try alias.next());
    try std.testing.expectEqual(@as(?u32, 4), try copied.next());
    try std.testing.expectEqual(@as(?u32, 5), try copied.next());
}

test "ring wrap and position rebasing preserve every independent cursor" {
    var source = try Stream(u32).init(allocator, io, 3);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var a = split.left.iterator();
    var b = split.right.iterator();
    for (0..128) |i| {
        const value: u32 = @intCast(i * 2);
        try source.push(value);
        try source.push(value + 1);
        try std.testing.expectEqual(@as(?u32, value), try a.next());
        var clone = try split.left.clone();
        defer clone.deinit();
        var c = clone.iterator();
        try std.testing.expectEqual(@as(?u32, value), try b.next());
        try std.testing.expectEqual(@as(?u32, value + 1), try c.next());
        try std.testing.expectEqual(@as(?u32, value + 1), try a.next());
        try std.testing.expectEqual(@as(?u32, value + 1), try b.next());
    }
}

test "closing a lagging reader releases capacity without closing its sibling" {
    var source = try Stream(u32).init(allocator, io, 1);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    try source.push(1);
    var left = split.left.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try left.next());
    var writer = try io.concurrent(send, .{ &source, 2 });
    defer writer.cancel(io) catch {};
    split.right.close();
    split.right.close();
    try writer.await(io);
    try std.testing.expectEqual(@as(?u32, 2), try left.next());
    source.close();
    try std.testing.expectEqual(@as(?u32, null), try left.next());
    try std.testing.expectError(error.ReaderClosed, split.right.clone());
}

test "closing the last reader rejects publication and never restarts a cold producer" {
    const Helpers = struct {
        fn source(called: *bool, output: *Stream(u32)) error{ Closed, Canceled }!void {
            called.* = true;
            try output.push(1);
        }
    };
    var called = false;
    {
        var source = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.source, &called);
        defer source.deinit();
        var split = try tee(&source);
        defer split.deinit();
        split.left.close();
        split.right.close();
        try std.testing.expectError(error.Closed, source.push(1));
        var input = split.left.iterator();
        try std.testing.expectError(error.ReaderClosed, input.next());
    }
    try std.testing.expect(!called);
}

test "last-reader close wakes a full writer with Closed" {
    var source = try Stream(u32).init(allocator, io, 1);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    try source.push(1);
    var writer = try io.concurrent(send, .{ &source, 2 });
    defer writer.cancel(io) catch {};
    split.left.close();
    split.right.close();
    try std.testing.expectError(error.Closed, writer.await(io));
}

const Waiting = struct {
    entered: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    close_early: bool = false,
    finished: bool = false,
};

fn waitProducer(waiting: *Waiting, output: *Stream(u32)) std.Io.Cancelable!void {
    defer waiting.finished = true;
    if (waiting.close_early) output.close();
    waiting.entered.set(io);
    try waiting.gate.wait(io);
}

test "tee rejects a pending default read and preserves it after cancellation" {
    var waiting: Waiting = .{};
    {
        var source = try Stream(u32).fromProducerWith(allocator, io, 1, waitProducer, &waiting);
        defer source.deinit();
        var consumer = try io.concurrent(receiveDefault, .{&source});
        defer _ = consumer.cancel(io) catch {};
        try waiting.entered.wait(io);
        try std.testing.expectError(error.Busy, tee(&source));
        try std.testing.expectError(error.Canceled, consumer.cancel(io));
        var split = try tee(&source);
        defer split.deinit();
    }
    try std.testing.expect(waiting.finished);
}

test "clone rejects a pending read; cancellation does not detach the reader" {
    var waiting: Waiting = .{};
    {
        var source = try Stream(u32).fromProducerWith(allocator, io, 1, waitProducer, &waiting);
        defer source.deinit();
        var split = try tee(&source);
        defer split.deinit();
        var consumer = try io.concurrent(receive, .{&split.left});
        defer _ = consumer.cancel(io) catch {};
        try waiting.entered.wait(io);
        try std.testing.expectError(error.Busy, split.left.clone());
        try std.testing.expectError(error.Canceled, consumer.cancel(io));
        var clone = try split.left.clone();
        defer clone.deinit();
    }
    try std.testing.expect(waiting.finished);
}

test "reader close interrupts an end wait without canceling the producer" {
    var waiting: Waiting = .{ .close_early = true };
    {
        var source = try Stream(u32).fromProducerWith(allocator, io, 1, waitProducer, &waiting);
        defer source.deinit();
        var split = try tee(&source);
        defer split.deinit();
        var consumer = try io.concurrent(receive, .{&split.left});
        defer _ = consumer.cancel(io) catch {};
        try waiting.entered.wait(io);
        split.left.close();
        try std.testing.expectError(error.ReaderClosed, consumer.await(io));
    }
    // Producer waited until owner deinit, which canceled and joined it.
    try std.testing.expect(waiting.finished);
}

test "producer completion wait is cancellable for rendezvous and bounded inputs" {
    for ([_]usize{ 0, 1 }) |capacity| {
        var waiting: Waiting = .{ .close_early = true };
        {
            var source = try Stream(u32).fromProducerWith(allocator, io, capacity, waitProducer, &waiting);
            defer source.deinit();
            var consumer = try io.concurrent(receiveDefault, .{&source});
            defer _ = consumer.cancel(io) catch {};
            try waiting.entered.wait(io);
            try std.testing.expectError(error.Canceled, consumer.cancel(io));
        }
        try std.testing.expect(waiting.finished);
    }
}

test "producer failure is cached independently after each reader drains" {
    const Helpers = struct {
        fn source(output: *Stream(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(1);
            try output.push(2);
            return error.Broken;
        }
    };
    var source = try Stream(u32).fromProducer(allocator, io, 2, Helpers.source);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var left = split.left.iterator();
    var right = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try left.next());
    try std.testing.expectEqual(@as(?u32, 2), try left.next());
    try std.testing.expectError(error.Broken, left.next());
    var clone = try split.left.clone();
    defer clone.deinit();
    var end = clone.iterator();
    try std.testing.expectError(error.Broken, end.next());
    try std.testing.expectEqual(@as(?u32, 1), try right.next());
    try std.testing.expectEqual(@as(?u32, 2), try right.next());
    try std.testing.expectError(error.Broken, right.next());
}

test "cloning an ended reader observes end without restarting production" {
    const Helpers = struct {
        fn source(calls: *usize, _: *Stream(u32)) void {
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    var source = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.source, &calls);
    defer source.deinit();
    var split = try tee(&source);
    defer split.deinit();
    var left = split.left.iterator();
    try std.testing.expectEqual(@as(?u32, null), try left.next());
    var clone = try split.left.clone();
    defer clone.deinit();
    var end = clone.iterator();
    try std.testing.expectEqual(@as(?u32, null), try end.next());
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "concurrent end readers join one producer and retain its failure" {
    const count = 8;
    const State = struct {
        ready: std.atomic.Value(usize) = .init(0),
        all_ready: std.Io.Event = .unset,
        finished: std.atomic.Value(usize) = .init(0),
    };
    const Helpers = struct {
        fn source(state: *State, _: *Stream(u32)) !void {
            defer _ = state.finished.fetchAdd(1, .monotonic);
            try state.all_ready.wait(io);
            return error.Broken;
        }
        fn read(state: *State, reader: *Stream(u32).Reader) anyerror!void {
            if (state.ready.fetchAdd(1, .acq_rel) == count - 1) state.all_ready.set(io);
            var cursor = reader.iterator();
            try std.testing.expectError(error.Broken, cursor.next());
            // Future results must remain cached, not consumed by the first join.
            try std.testing.expectError(error.Broken, cursor.next());
        }
    };
    // Exercise concurrent completion joins, not just sequential cached reads.
    for (0..16) |_| {
        var state: State = .{};
        var source = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.source, &state);
        defer source.deinit();
        var split = try tee(&source);
        defer split.deinit();
        var clones: [count - 2]Stream(u32).Reader = undefined;
        var prepared: usize = 0;
        defer for (clones[0..prepared]) |*reader| reader.deinit();
        for (&clones) |*reader| {
            reader.* = try split.left.clone();
            prepared += 1;
        }
        var workers: [count]std.Io.Future(anyerror!void) = undefined;
        var started: usize = 0;
        defer for (workers[0..started]) |*task| task.cancel(io) catch {};
        for (&workers, 0..) |*task, i| {
            const reader = if (i == 0) &split.left else if (i == 1) &split.right else &clones[i - 2];
            task.* = try io.concurrent(Helpers.read, .{ &state, reader });
            started += 1;
        }
        for (&workers) |*task| try task.await(io);
        try std.testing.expectEqual(@as(usize, 1), state.finished.load(.monotonic));
    }
}

test "branching rejects zero capacity without changing or activating the source" {
    const Helpers = struct {
        fn source(calls: *usize, output: *Stream(u32)) error{ Closed, Canceled }!void {
            calls.* += 1;
            try produce(output);
        }
    };
    var calls: usize = 0;
    var source = try Stream(u32).fromProducerWith(allocator, io, 0, Helpers.source, &calls);
    defer source.deinit();
    try std.testing.expectError(error.UnsupportedCapacity, tee(&source));
    try std.testing.expectEqual(@as(usize, 0), calls);
    var output: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, try pipe(&source, .{collectInto(&output)}));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "branch item errors and nulls stay data through filter and each" {
    const Data = error{ Canceled, Closed }!?u32;
    const Helpers = struct {
        fn same(value: Data) Data {
            return value;
        }
        fn accept(_: Data) bool {
            return true;
        }
    };
    var source = try Stream(Data).init(allocator, io, 3);
    defer source.deinit();
    try source.push(error.Canceled);
    try source.push(error.Closed);
    try source.push(null);
    source.close();
    var split = try tee(&source);
    defer split.deinit();
    var output: [3]Data = undefined;
    const values = try pipe(&split.left, .{ filter(Helpers.accept), each(Helpers.same), collectInto(&output) });
    try std.testing.expectError(error.Canceled, values[0]);
    try std.testing.expectError(error.Closed, values[1]);
    try std.testing.expectEqual(@as(?u32, null), try values[2]);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var source = try Stream(u32).init(gpa, io, 1);
    defer source.deinit();
    try source.push(7);
    source.close();
    var split = tee(&source) catch |err| {
        var original = source.iterator();
        try std.testing.expectEqual(@as(?u32, 7), try original.next());
        return err;
    };
    defer split.deinit();
    var clone = split.left.clone() catch |err| {
        var original = split.left.iterator();
        try std.testing.expectEqual(@as(?u32, 7), try original.next());
        return err;
    };
    defer clone.deinit();
    var a = split.left.iterator();
    var b = split.right.iterator();
    var c = clone.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try a.next());
    try std.testing.expectEqual(@as(?u32, 7), try b.next());
    try std.testing.expectEqual(@as(?u32, 7), try c.next());
}

test "tee and clone allocation failures preserve the original claim and free metadata" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
