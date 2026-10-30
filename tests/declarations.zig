const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const forEach = zrx.forEach;
const forEachWith = zrx.forEachWith;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn Values(comptime T: type) type {
    return struct {
        data: [8]T = undefined,
        len: usize = 0,
        fn append(self: *@This(), value: T) error{TooMany}!void {
            if (self.len == self.data.len) return error.TooMany;
            self.data[self.len] = value;
            self.len += 1;
        }
        fn slice(self: *@This()) []const T {
            return self.data[0..self.len];
        }
    };
}

fn produce(output: *Emitter(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
}

test "declarations need no resources and two flows see the same capacity-one input" {
    const Helpers = struct {
        fn source(calls: *std.atomic.Value(usize), output: *Emitter(u32)) error{ Closed, Canceled }!void {
            _ = calls.fetchAdd(1, .monotonic);
            try produce(output);
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    const source: Stream(u32) = .fromProducerWith(1, Helpers.source, &calls);
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    const first = pipe(&source, .{forEachWith(&a, Values(u32).append)});
    const second = pipe(&source, .{forEachWith(&b, Values(u32).append)});
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
    // A second run creates fresh transport and calls the producer again.
    a.len = 0;
    b.len = 0;
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
    try std.testing.expectEqual(@as(usize, 2), calls.load(.monotonic));
}

test "source descriptions can be constructed at comptime and have no live operations" {
    const source = comptime Stream(u32).fromProducer(1, produce);
    inline for (.{ "init", "push", "close", "deinit", "iterator", "instantiate" }) |name|
        try std.testing.expect(!@hasDecl(@TypeOf(source), name));
    try std.testing.expect(!@hasDecl(zrx, "tee"));
    try std.testing.expect(!@hasDecl(zrx, "share"));
    try std.testing.expect(!@hasDecl(zrx, "collectInto"));
    try std.testing.expect(!@hasDecl(zrx, "collectAlloc"));
    var values: Values(u32) = .{};
    try run(allocator, io, .{pipe(&source, .{forEachWith(&values, Values(u32).append)})});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, values.slice());
}

test "by-value source descriptions instantiate independent producers with current configuration" {
    const Context = struct { calls: std.atomic.Value(usize) = .init(0), value: u32 = 1 };
    const Helpers = struct {
        fn source(context: *Context, output: *Emitter(u32)) error{ Closed, Canceled }!void {
            _ = context.calls.fetchAdd(1, .monotonic);
            try output.push(context.value);
        }
    };
    var context: Context = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &context);
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    const first = pipe(source, .{forEachWith(&a, Values(u32).append)});
    const second = pipe(source, .{forEachWith(&b, Values(u32).append)});
    context.value = 7;
    try run(allocator, io, .{ first, second });
    try std.testing.expectEqual(@as(usize, 2), context.calls.load(.monotonic));
    try std.testing.expectEqualSlices(u32, &.{7}, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
}

const Number = struct { value: u32, evaluations: *std.atomic.Value(usize) };
fn numbers(calls: *std.atomic.Value(usize), output: *Emitter(Number)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(.{ .value = value, .evaluations = calls });
}
fn double(number: Number) u32 {
    _ = number.evaluations.fetchAdd(1, .monotonic);
    return number.value * 2;
}

test "one referenced derived declaration evaluates once for three consumers" {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(Number).fromProducerWith(1, numbers, &calls);
    const doubled = pipe(&source, .{each(double)});
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    var c: Values(u32) = .{};
    const first = pipe(&doubled, .{forEachWith(&a, Values(u32).append)});
    const second = pipe(&doubled, .{forEachWith(&b, Values(u32).append)});
    const third = pipe(&doubled, .{forEachWith(&c, Values(u32).append)});
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try run(allocator, io, .{ first, second, third });
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), c.slice());
    try std.testing.expectEqual(@as(usize, 3), calls.load(.monotonic));
}

test "separate and by-value derived declarations remain independent" {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(Number).fromProducerWith(1, numbers, &calls);
    const one = pipe(&source, .{each(double)});
    const two = pipe(&source, .{each(double)});
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    try run(allocator, io, .{
        pipe(&one, .{forEachWith(&a, Values(u32).append)}),
        pipe(&two, .{forEachWith(&b, Values(u32).append)}),
    });
    try std.testing.expectEqual(@as(usize, 6), calls.load(.monotonic));
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
    a.len = 0;
    b.len = 0;
    calls.store(0, .monotonic);
    try run(allocator, io, .{
        pipe(one, .{forEachWith(&a, Values(u32).append)}),
        pipe(one, .{forEachWith(&b, Values(u32).append)}),
    });
    try std.testing.expectEqual(@as(usize, 6), calls.load(.monotonic));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
}

test "empty sources and filtered-out inputs finish without invoking effects" {
    const Helpers = struct {
        fn empty(_: *Emitter(u32)) void {}
        fn never(_: u32) bool {
            return false;
        }
    };
    const empty = Stream(u32).fromProducer(1, Helpers.empty);
    const source = Stream(u32).fromProducer(1, produce);
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    try run(allocator, io, .{
        pipe(&empty, .{forEachWith(&a, Values(u32).append)}),
        pipe(&source, .{ filter(Helpers.never), forEachWith(&b, Values(u32).append) }),
    });
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
}

test "unselected sources and flows do not activate or retain a reader" {
    const Helpers = struct {
        fn forbidden(_: *Emitter(u32)) void {
            @panic("unselected producer started");
        }
        fn forbiddenMap(_: u32) u32 {
            @panic("unselected transform ran");
        }
    };
    const source = Stream(u32).fromProducer(1, produce);
    const unused_source = Stream(u32).fromProducer(1, Helpers.forbidden);
    const unused = pipe(&source, .{each(Helpers.forbiddenMap)});
    var ignored: Values(u32) = .{};
    _ = pipe(&unused_source, .{forEachWith(&ignored, Values(u32).append)});
    _ = pipe(&unused, .{forEachWith(&ignored, Values(u32).append)});
    var selected: Values(u32) = .{};
    try run(allocator, io, .{pipe(&source, .{forEachWith(&selected, Values(u32).append)})});
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, selected.slice());
    try std.testing.expectEqual(@as(usize, 0), ignored.len);
}

test "nested filters maps type transitions and heterogeneous capabilities" {
    const Helpers = struct {
        fn even(value: u32) bool {
            return value % 2 == 0;
        }
        fn widen(value: u32) u64 {
            return @as(u64, value) * 2;
        }
        fn positive(value: u64) bool {
            return value > 0;
        }
    };
    const source = Stream(u32).fromProducer(1, produce);
    const selected = pipe(&source, .{ filter(Helpers.even), each(Helpers.widen) });
    const flag = pipe(&selected, .{each(Helpers.positive)});
    var values: Values(u64) = .{};
    var flags: Values(bool) = .{};
    try run(allocator, io, .{
        pipe(&selected, .{forEachWith(&values, Values(u64).append)}),
        pipe(&flag, .{forEachWith(&flags, Values(bool).append)}),
    });
    try std.testing.expectEqualSlices(u64, &.{4}, values.slice());
    try std.testing.expectEqualSlices(bool, &.{true}, flags.slice());
}

test "grouped and separate declarations preserve error-union and optional items" {
    const Data = error{Odd}!?u32;
    const Helpers = struct {
        fn checked(value: u32) Data {
            return if (value == 1) error.Odd else if (value == 2) null else value;
        }
        fn recover(value: Data) u32 {
            return (value catch return 0) orelse 9;
        }
    };
    const source = Stream(u32).fromProducer(1, produce);
    const grouped = pipe(&source, .{each(.{ Helpers.checked, Helpers.recover })});
    const separate = pipe(&source, .{ each(Helpers.checked), each(Helpers.recover) });
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    try run(allocator, io, .{
        pipe(&grouped, .{forEachWith(&a, Values(u32).append)}),
        pipe(&separate, .{forEachWith(&b, Values(u32).append)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 0, 9, 3 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), b.slice());
}

test "callback failure cancels peers and managed producers preserving the primary error" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        source_finished: std.atomic.Value(bool) = .init(false),
        peer_finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) error{ Closed, Canceled }!void {
            defer state.source_finished.store(true, .release);
            while (true) try output.push(1);
        }
        fn reject(state: *State, _: u32) error{ Canceled, Stop }!void {
            try state.entered.wait(io);
            return error.Stop;
        }
        fn wait(state: *State, _: u32) std.Io.Cancelable!void {
            defer state.peer_finished.store(true, .release);
            state.entered.set(io);
            try state.gate.wait(io);
        }
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    const derived = pipe(&source, .{each(identity)});
    try std.testing.expectError(error.Stop, run(allocator, io, .{
        pipe(&derived, .{forEachWith(&state, Helpers.reject)}),
        pipe(&derived, .{forEachWith(&state, Helpers.wait)}),
    }));
    try std.testing.expect(state.source_finished.load(.acquire));
    try std.testing.expect(state.peer_finished.load(.acquire));
}

fn identity(value: u32) u32 {
    return value;
}

test "source failure follows an observed common prefix" {
    const State = struct {
        count: std.atomic.Value(usize) = .init(0),
        observed: std.Io.Event = .unset,
    };
    const Sink = struct {
        state: *State,
        values: Values(u32) = .{},
        fn consume(self: *@This(), value: u32) error{TooMany}!void {
            try self.values.append(value);
            if (self.state.count.fetchAdd(1, .acq_rel) == 3) self.state.observed.set(io);
        }
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) error{ Closed, Canceled, Broken }!void {
            try output.push(1);
            try output.push(2);
            try state.observed.wait(output.io);
            return error.Broken;
        }
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    var a: Sink = .{ .state = &state };
    var b: Sink = .{ .state = &state };
    try std.testing.expectError(error.Broken, run(allocator, io, .{
        pipe(&source, .{forEachWith(&a, Sink.consume)}),
        pipe(&source, .{forEachWith(&b, Sink.consume)}),
    }));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, a.values.slice());
    try std.testing.expectEqualSlices(u32, a.values.slice(), b.values.slice());
}

test "parent cancellation joins a producer waiting on the run Io" {
    const State = struct {
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn source(state: *State, output: *Emitter(u32)) std.Io.Cancelable!void {
            defer state.finished.store(true, .release);
            state.entered.set(output.io);
            try state.gate.wait(output.io);
        }
        fn ignore(_: u32) void {}
        fn execute(input: *const Stream(u32)) !void {
            try run(allocator, io, .{pipe(input, .{forEach(ignore)})});
        }
    };
    var state: State = .{};
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &state);
    var execution = try io.concurrent(Helpers.execute, .{&source});
    defer execution.cancel(io) catch {};
    try state.entered.wait(io);
    try std.testing.expectError(error.Canceled, execution.cancel(io));
    try std.testing.expect(state.finished.load(.acquire));
}

test "startup failure never activates a partial graph and the declaration can be retried" {
    const Helpers = struct {
        fn source(called: *std.atomic.Value(bool), output: *Emitter(u32)) error{ Closed, Canceled }!void {
            called.store(true, .release);
            try output.push(1);
        }
        fn ignore(_: u32) void {}
    };
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer backend.deinit();
    var called: std.atomic.Value(bool) = .init(false);
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &called);
    const first = pipe(&source, .{forEach(Helpers.ignore)});
    const second = pipe(&source, .{forEach(Helpers.ignore)});
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), .{ first, second }));
    try std.testing.expect(!called.load(.acquire));
    try run(allocator, io, .{ first, second });
    try std.testing.expect(called.load(.acquire));
}

test "producer receives allocator and Io from run and const capability coercion works" {
    const Context = struct { value: u32, expected_io: std.Io, expected_allocator: std.mem.Allocator };
    const Helpers = struct {
        fn source(context: *const Context, output: *Emitter(u32)) !void {
            try std.testing.expectEqual(context.expected_io.userdata, output.io.userdata);
            try std.testing.expectEqual(context.expected_io.vtable, output.io.vtable);
            try std.testing.expectEqual(context.expected_allocator.ptr, output.allocator.ptr);
            try std.testing.expectEqual(context.expected_allocator.vtable, output.allocator.vtable);
            const scratch = try output.allocator.alloc(u8, 8);
            defer output.allocator.free(scratch);
            try output.push(context.value);
        }
    };
    var backend: std.Io.Threaded = .init(allocator, .{});
    defer backend.deinit();
    var context: Context = .{ .value = 7, .expected_io = backend.io(), .expected_allocator = allocator };
    const source = Stream(u32).fromProducerWith(1, Helpers.source, &context);
    var values: Values(u32) = .{};
    try run(allocator, backend.io(), .{pipe(&source, .{forEachWith(&values, Values(u32).append)})});
    try std.testing.expectEqualSlices(u32, &.{7}, values.slice());
}

test "zero capacity is rejected at execution without starting production" {
    const Helpers = struct {
        fn forbidden(_: *Emitter(u32)) void {
            @panic("zero-capacity graph activated");
        }
        fn ignore(_: u32) void {}
    };
    const source = Stream(u32).fromProducer(0, Helpers.forbidden);
    try std.testing.expectError(error.UnsupportedCapacity, run(allocator, io, .{
        pipe(&source, .{forEach(Helpers.ignore)}),
    }));
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(Number).fromProducerWith(1, numbers, &calls);
    const node = pipe(&source, .{each(double)});
    var a: Values(u32) = .{};
    var b: Values(u32) = .{};
    var c: Values(u32) = .{};
    var d: Values(u32) = .{};
    run(gpa, io, .{
        pipe(&node, .{forEachWith(&a, Values(u32).append)}),
        pipe(&node, .{forEachWith(&b, Values(u32).append)}),
        pipe(&node, .{forEachWith(&c, Values(u32).append)}),
        pipe(&node, .{forEachWith(&d, Values(u32).append)}),
    }) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
            // Failed preparation did not consume or invalidate the declaration.
            try run(allocator, io, .{pipe(&node, .{forEachWith(&a, Values(u32).append)})});
            try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, a.slice());
        }
        return err;
    };
    try std.testing.expectEqual(@as(usize, 3), calls.load(.monotonic));
    try std.testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, a.slice());
    try std.testing.expectEqualSlices(u32, a.slice(), d.slice());
}

test "every execution preparation allocation failure cleans up and permits retry" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
