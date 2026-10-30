const std = @import("std");
// Internal materialization coverage; application sharing is exercised in declarations.zig.
const zrx = @import("zrx");
const Stream = zrx.Stream;
const share = zrx.share;
const tee = zrx.tee;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const collectInto = zrx.collectInto;
const collectAlloc = zrx.collectAlloc;
const fromIterator = zrx.fromIterator;
const readFrom = zrx.readFrom;
const io = std.testing.io;
const allocator = std.testing.allocator;

fn collect(reader: *Stream(u32).Reader, buffer: *[3]u32) ![]u32 {
    return pipe(reader, .{collectInto(buffer)});
}

const Counted = struct {
    value: u32,
    calls: *std.atomic.Value(usize),
};

fn doubleAndCount(value: Counted) u32 {
    _ = value.calls.fetchAdd(1, .monotonic);
    return value.value * 2;
}

test "share evaluates once before tee and stays lazy during declaration" {
    var calls: std.atomic.Value(usize) = .init(0);
    const input = [_]Counted{
        .{ .value = 1, .calls = &calls },
        .{ .value = 2, .calls = &calls },
        .{ .value = 3, .calls = &calls },
    };
    const computed = pipe(&input, .{each(doubleAndCount)});
    var shared = try share(allocator, io, 1, computed);
    defer shared.deinit();
    var split = try tee(&shared);
    defer split.deinit();
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    var left_storage: [3]u32 = undefined;
    var left = try io.concurrent(collect, .{ &split.left, &left_storage });
    defer _ = left.cancel(io) catch {};
    var right_storage: [3]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, try pipe(&split.right, .{collectInto(&right_storage)}));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, try left.await(io));
    try std.testing.expectEqual(@as(usize, 3), calls.load(.monotonic));
    var end = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, null), try end.next());
    try std.testing.expectEqual(@as(usize, 3), calls.load(.monotonic));
}

test "shared computation before a rejected publication is not rolled back" {
    const Data = struct {
        value: u32,
        calls: *std.atomic.Value(usize),
        second_computed: *std.Io.Event,
    };
    const Helpers = struct {
        fn compute(data: Data) u32 {
            _ = data.calls.fetchAdd(1, .monotonic);
            if (data.value == 2) data.second_computed.set(io);
            return data.value;
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    var second_computed: std.Io.Event = .unset;
    const input = [_]Data{
        .{ .value = 1, .calls = &calls, .second_computed = &second_computed },
        .{ .value = 2, .calls = &calls, .second_computed = &second_computed },
        .{ .value = 3, .calls = &calls, .second_computed = &second_computed },
    };
    var shared = try share(allocator, io, 1, pipe(&input, .{each(Helpers.compute)}));
    defer shared.deinit();
    var split = try tee(&shared);
    defer split.deinit();
    var left = split.left.iterator();
    var right = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try left.next());
    try second_computed.wait(io);
    // Right still pins the first item: item 2 has effects but cannot publish.
    shared.close();
    try std.testing.expectEqual(@as(?u32, 1), try right.next());
    try std.testing.expectError(error.Closed, left.next());
    try std.testing.expectError(error.Closed, right.next());
    try std.testing.expectEqual(@as(usize, 2), calls.load(.monotonic));
}

test "unused and closed-before-read sharing does not consume its input" {
    const Input = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) ?u32 {
            self.calls += 1;
            return null;
        }
    };
    var input: Input = .{};
    {
        var shared = try share(allocator, io, 1, fromIterator(&input));
        defer shared.deinit();
        _ = shared.iterator();
    }
    try std.testing.expectEqual(@as(usize, 0), input.calls);
    var shared = try share(allocator, io, 1, fromIterator(&input));
    defer shared.deinit();
    shared.close();
    var end = shared.iterator();
    try std.testing.expectEqual(@as(?u32, null), try end.next());
    try std.testing.expectEqual(@as(usize, 0), input.calls);
}

test "shared type transitions and grouped transformations reuse sequence rules" {
    const Helpers = struct {
        fn double(value: u32) u32 {
            return value * 2;
        }
        fn widen(value: u32) u64 {
            return value + 1;
        }
    };
    const input = [_]u8{ 1, 2, 3 };
    var a = try share(allocator, io, 1, pipe(&input, .{each(.{ Helpers.double, Helpers.widen })}));
    defer a.deinit();
    var b = try share(allocator, io, 1, pipe(&input, .{ each(Helpers.double), each(Helpers.widen) }));
    defer b.deinit();
    try std.testing.expectEqual(Stream(u64), @TypeOf(a));
    var first: [3]u64 = undefined;
    var second: [3]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{ 3, 5, 7 }, try pipe(&a, .{collectInto(&first)}));
    try std.testing.expectEqualSlices(u64, &first, try pipe(&b, .{collectInto(&second)}));
}

test "empty and filtered-out shared inputs finish without output" {
    const Helpers = struct {
        fn reject(_: u32) bool {
            return false;
        }
    };
    const empty = [_]u32{};
    var a = try share(allocator, io, 1, &empty);
    defer a.deinit();
    var first = a.iterator();
    try std.testing.expectEqual(@as(?u32, null), try first.next());
    const input = [_]u32{ 1, 2, 3 };
    var b = try share(allocator, io, 1, pipe(&input, .{filter(Helpers.reject)}));
    defer b.deinit();
    var second = b.iterator();
    try std.testing.expectEqual(@as(?u32, null), try second.next());
}

test "each shared reader drains the prefix before receiving the same source error" {
    const Input = struct {
        value: u32 = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.value += 1;
            if (self.value == 3) return error.Broken;
            return self.value;
        }
    };
    var input: Input = .{};
    var shared = try share(allocator, io, 2, fromIterator(&input));
    defer shared.deinit();
    var split = try tee(&shared);
    defer split.deinit();
    var a = split.left.iterator();
    var b = split.right.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try a.next());
    try std.testing.expectEqual(@as(?u32, 2), try a.next());
    try std.testing.expectError(error.Broken, a.next());
    try std.testing.expectEqual(@as(?u32, 1), try b.next());
    try std.testing.expectEqual(@as(?u32, 2), try b.next());
    try std.testing.expectError(error.Broken, b.next());
    try std.testing.expectError(error.Broken, b.next());
    try std.testing.expectEqual(@as(u32, 3), input.value);
}

test "shared transformed error unions and nulls remain items" {
    const Data = error{ Canceled, Closed }!?u32;
    const Helpers = struct {
        fn toData(value: u32) Data {
            return switch (value) {
                0 => error.Canceled,
                1 => error.Closed,
                else => null,
            };
        }
    };
    const input = [_]u32{ 0, 1, 2 };
    var shared = try share(allocator, io, 1, pipe(&input, .{each(Helpers.toData)}));
    defer shared.deinit();
    var output: [3]Data = undefined;
    const values = try pipe(&shared, .{collectInto(&output)});
    try std.testing.expectError(error.Canceled, values[0]);
    try std.testing.expectError(error.Closed, values[1]);
    try std.testing.expectEqual(@as(?u32, null), try values[2]);
}

test "bare error-set input items can be shared as data" {
    const Data = error{ Canceled, Closed };
    const input = [_]Data{ error.Canceled, error.Closed };
    var shared = try share(allocator, io, 1, &input);
    defer shared.deinit();
    var output: [2]Data = undefined;
    try std.testing.expectEqualSlices(Data, &input, try pipe(&shared, .{collectInto(&output)}));
}

test "optional shared items do not become end markers" {
    const input = [_]?u32{ null, 7 };
    var shared = try share(allocator, io, 1, &input);
    defer shared.deinit();
    var output: [2]?u32 = undefined;
    try std.testing.expectEqualSlices(?u32, &input, try pipe(&shared, .{collectInto(&output)}));
}

test "sharing a standard queue does not take ownership or close it" {
    var storage: [1]u32 = undefined;
    var input: std.Io.Queue(u32) = .init(&storage);
    defer input.close(io);
    try input.putOne(io, 7);
    {
        var shared = try share(allocator, io, 1, readFrom(io, &input));
        defer shared.deinit();
        var reader = shared.iterator();
        try std.testing.expectEqual(@as(?u32, 7), try reader.next());
    }
    try input.putOne(io, 9);
    try std.testing.expectEqual(@as(u32, 9), try input.getOne(io));
}

test "sharing borrows independent reader metadata and leaves it usable after shutdown" {
    var input = try Stream(u32).init(allocator, io, 1);
    defer input.deinit();
    var split = try tee(&input);
    defer split.deinit();
    split.right.close();
    try input.push(1);
    {
        var shared = try share(allocator, io, 1, &split.left);
        defer shared.deinit();
        var reader = shared.iterator();
        try std.testing.expectEqual(@as(?u32, 1), try reader.next());
    }
    var clone = try split.left.clone();
    defer clone.deinit();
    clone.close();
    try input.push(2);
    input.close();
    var reader = split.left.iterator();
    try std.testing.expectEqual(@as(?u32, 2), try reader.next());
    try std.testing.expectEqual(@as(?u32, null), try reader.next());
}

test "shared owner cancellation joins its forwarder but not its upstream producer" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn produce(state: *State, output: *Stream(u32)) error{ Closed, Canceled }!void {
            defer state.finished.store(true, .release);
            try output.push(1);
            state.entered.set(io);
            try state.gate.wait(io);
            try output.push(2);
        }
    };
    var state: State = .{};
    var input = try Stream(u32).fromProducerWith(allocator, io, 1, Helpers.produce, &state);
    defer input.deinit();
    {
        var shared = try share(allocator, io, 1, &input);
        defer shared.deinit();
        var reader = shared.iterator();
        try std.testing.expectEqual(@as(?u32, 1), try reader.next());
        try state.entered.wait(io);
    }
    try std.testing.expect(!state.finished.load(.acquire));
    state.gate.set(io);
    var original = input.iterator();
    try std.testing.expectEqual(@as(?u32, 2), try original.next());
    try std.testing.expectEqual(@as(?u32, null), try original.next());
    try std.testing.expect(state.finished.load(.acquire));
}

test "zero capacity is rejected without touching the input" {
    const Input = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) ?u32 {
            self.calls += 1;
            return null;
        }
    };
    var input: Input = .{};
    try std.testing.expectError(error.UnsupportedCapacity, share(allocator, io, 0, fromIterator(&input)));
    try std.testing.expectEqual(@as(usize, 0), input.calls);
}

test "unavailable forwarding concurrency does not fall back to eager input work" {
    const Input = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) ?u32 {
            self.calls += 1;
            return null;
        }
    };
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .nothing });
    defer backend.deinit();
    var input: Input = .{};
    var shared = try share(allocator, backend.io(), 1, fromIterator(&input));
    defer shared.deinit();
    var reader = shared.iterator();
    try std.testing.expectError(error.ConcurrencyUnavailable, reader.next());
    try std.testing.expectEqual(@as(usize, 0), input.calls);
}

test "upstream concurrency failure propagates through the shared owner" {
    const Helpers = struct {
        fn produce(called: *std.atomic.Value(bool), output: *Stream(u32)) error{ Closed, Canceled }!void {
            called.store(true, .release);
            try output.push(1);
        }
    };
    // Only the forwarder can run; it cannot start another producer task.
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var called: std.atomic.Value(bool) = .init(false);
    var input = try Stream(u32).fromProducerWith(allocator, backend.io(), 1, Helpers.produce, &called);
    defer input.deinit();
    var shared = try share(allocator, backend.io(), 1, &input);
    defer shared.deinit();
    var reader = shared.iterator();
    try std.testing.expectError(error.ConcurrencyUnavailable, reader.next());
    try std.testing.expect(!called.load(.acquire));
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const input = [_]u32{ 1, 2, 3 };
    var shared = try share(gpa, io, 1, &input);
    defer shared.deinit();
    const output = try pipe(&shared, .{collectAlloc(gpa)});
    defer gpa.free(output);
    try std.testing.expectEqualSlices(u32, &input, output);
}

test "allocation failures release shared state and stop an early forwarder" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}

test "source errors free partially allocated output" {
    const Input = struct {
        count: usize = 0,
        pub fn next(self: *@This()) error{Broken}!?u32 {
            self.count += 1;
            return if (self.count == 1) @as(?u32, 7) else error.Broken;
        }
    };
    var input: Input = .{};
    var shared = try share(allocator, io, 1, fromIterator(&input));
    defer shared.deinit();
    try std.testing.expectError(error.Broken, pipe(&shared, .{collectAlloc(allocator)}));
}
