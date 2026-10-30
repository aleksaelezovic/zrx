const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const each = zrx.each;
const hold = zrx.hold;
const values = zrx.values;
const withLatestFrom = zrx.withLatestFrom;
const forEachWith = zrx.forEachWith;
const collectThenWith = zrx.collectThenWith;
const batchThenWith = zrx.batchThenWith;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;

fn Saved(comptime T: type) type {
    return struct {
        data: [32]T = undefined,
        len: usize = 0,
        calls: usize = 0,
        fn append(self: *@This(), value: T) !void {
            if (self.len == self.data.len) return error.NoSpaceLeft;
            self.data[self.len] = value;
            self.len += 1;
        }
        fn copy(self: *@This(), items: []const T) !void {
            if (items.len > self.data.len) return error.NoSpaceLeft;
            @memcpy(self.data[0..items.len], items);
            self.len = items.len;
            self.calls += 1;
        }
        fn slice(self: *@This()) []const T {
            return self.data[0..self.len];
        }
    };
}

test "hold observes initial and equal replacements in order and resets per run" {
    const updates = [_]i32{ 23, 23, 18 };
    const current = pipe(&updates, .{hold(20)});
    var saved: Saved(i32) = .{};
    const flow = pipe(values(&current), .{collectThenWith(&saved, Saved(i32).copy)});
    try std.testing.expectEqual(@as(usize, 0), saved.calls);
    for (0..2) |_| {
        try run(allocator, io, .{flow});
        try std.testing.expectEqualSlices(i32, &.{ 20, 23, 23, 18 }, saved.slice());
    }
    try std.testing.expectEqual(@as(usize, 2), saved.calls);
}

test "signal maps are shared deferred and initialize before replacements" {
    const Helpers = struct {
        var calls: usize = 0;
        fn double(value: u32) u64 {
            calls += 1;
            return @as(u64, value) * 2;
        }
    };
    Helpers.calls = 0;
    const updates = [_]u32{ 1, 2, 3 };
    const current = pipe(&updates, .{hold(0)});
    const doubled = pipe(&current, .{map(Helpers.double)});
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    var c: Saved(u64) = .{};
    const first = pipe(values(&doubled), .{forEachWith(&a, Saved(u64).append)});
    const second = pipe(values(&doubled), .{collectThenWith(&b, Saved(u64).copy)});
    const third = pipe(values(&doubled), .{forEachWith(&c, Saved(u64).append)});
    try std.testing.expectEqual(@as(usize, 0), Helpers.calls);
    try run(allocator, io, .{ first, second, third });
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 4, 6 }, a.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), b.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), c.slice());
    try std.testing.expectEqual(@as(usize, 4), Helpers.calls);
}

test "empty updates still publish initial state and permit typed literal initials" {
    const Mode = enum { cold, hot };
    const no_modes = [_]Mode{};
    const no_optional = [_]?u32{};
    const mode = pipe(&no_modes, .{hold(.cold)});
    const optional = pipe(&no_optional, .{hold(null)});
    var a: Saved(Mode) = .{};
    var b: Saved(?u32) = .{};
    try run(allocator, io, .{
        pipe(values(&mode), .{collectThenWith(&a, Saved(Mode).copy)}),
        pipe(values(&optional), .{collectThenWith(&b, Saved(?u32).copy)}),
    });
    try std.testing.expectEqualSlices(Mode, &.{.cold}, a.slice());
    try std.testing.expectEqualSlices(?u32, &.{null}, b.slice());
}

test "equal derived values still publish every replacement" {
    const Helpers = struct {
        fn constant(_: u32) bool {
            return true;
        }
    };
    const updates = [_]u32{ 1, 2 };
    const current = pipe(&updates, .{hold(0)});
    const derived = pipe(&current, .{map(Helpers.constant)});
    var saved: Saved(bool) = .{};
    try run(allocator, io, .{pipe(values(&derived), .{collectThenWith(&saved, Saved(bool).copy)})});
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, saved.slice());
}

test "optional and error-union state publications remain data" {
    const Data = error{Bad}!?u32;
    const updates = [_]Data{ error.Bad, null, 7 };
    const current = pipe(&updates, .{hold(@as(Data, 1))});
    var saved: Saved(Data) = .{};
    try run(allocator, io, .{pipe(values(&current), .{collectThenWith(&saved, Saved(Data).copy)})});
    try std.testing.expectEqual(@as(usize, 4), saved.len);
    try std.testing.expectEqual(@as(?u32, 1), try saved.data[0]);
    try std.testing.expectError(error.Bad, saved.data[1]);
    try std.testing.expectEqual(@as(?u32, null), try saved.data[2]);
    try std.testing.expectEqual(@as(?u32, 7), try saved.data[3]);
    try std.testing.expectEqual(@as(usize, 1), saved.calls);
}

test "sampling pairs events with initial state using normal tuples without a values observer" {
    const updates = [_]i32{};
    const events = [_]u32{ 1, 2, 3 };
    const current = pipe(&updates, .{hold(20)});
    const Pair = @Tuple(&.{ u32, i32 });
    var saved: Saved(Pair) = .{};
    try run(allocator, io, .{pipe(&events, .{
        withLatestFrom(&current),
        collectThenWith(&saved, Saved(Pair).copy),
    })});
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    for (saved.slice(), events) |pair, event| {
        try std.testing.expectEqual(event, pair[0]);
        try std.testing.expectEqual(@as(i32, 20), pair[1]);
    }
}

test "runtime initial values are copied and unused signals do not activate or derive" {
    const Helpers = struct {
        fn forbidden(_: *Emitter(i32)) void {
            @panic("unused signal activated");
        }
        fn forbiddenMap(_: i32) i32 {
            @panic("unused signal mapped");
        }
    };
    const unused_source = Stream(i32).fromProducer(1, Helpers.forbidden);
    const unused_root = pipe(&unused_source, .{hold(10)});
    const unused_derived = pipe(&unused_root, .{map(Helpers.forbiddenMap)});
    var ignored: Saved(i32) = .{};
    _ = pipe(values(&unused_derived), .{collectThenWith(&ignored, Saved(i32).copy)});
    const empty = [_]i32{};
    var initial: i32 = 20;
    const current = pipe(&empty, .{hold(initial)});
    initial = 99;
    var saved: Saved(i32) = .{};
    try run(allocator, io, .{pipe(values(&current), .{collectThenWith(&saved, Saved(i32).copy)})});
    try std.testing.expectEqualSlices(i32, &.{20}, saved.slice());
}

test "grouped and separate signal maps preserve error values under pipe and tryPipe" {
    const Data = error{Odd}!u32;
    const Helpers = struct {
        fn checked(value: u32) Data {
            return if (value % 2 == 0) value else error.Odd;
        }
        fn recover(value: Data) u64 {
            return value catch 0;
        }
    };
    const updates = [_]u32{ 2, 3, 4 };
    const current = pipe(&updates, .{hold(1)});
    const grouped = pipe(&current, .{map(.{ Helpers.checked, Helpers.recover })});
    const checked_group = try tryPipe(&current, .{map(.{ Helpers.checked, Helpers.recover })});
    const checked_separate = try tryPipe(&current, .{ map(Helpers.checked), map(Helpers.recover) });
    var a: Saved(u64) = .{};
    var b: Saved(u64) = .{};
    var c: Saved(u64) = .{};
    try run(allocator, io, .{
        pipe(values(&grouped), .{collectThenWith(&a, Saved(u64).copy)}),
        pipe(values(&checked_group), .{collectThenWith(&b, Saved(u64).copy)}),
        pipe(values(&checked_separate), .{collectThenWith(&c, Saved(u64).copy)}),
    });
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 0, 4 }, a.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), b.slice());
    try std.testing.expectEqualSlices(u64, a.slice(), c.slice());
}

test "signal map transforms whole arrays and slices rather than their elements" {
    const Helpers = struct {
        fn total(data: [2]u32) u32 {
            return data[0] + data[1];
        }
        fn length(data: []const u32) usize {
            return data.len;
        }
    };
    const updates = [_][2]u32{ .{ 3, 4 }, .{ 5, 6 } };
    const current = pipe(&updates, .{hold([_]u32{ 0, 1 })});
    const total = pipe(&current, .{map(Helpers.total)});
    const first = [_]u32{ 1, 2 };
    const second = [_]u32{ 3, 4, 5 };
    const slices = [_][]const u32{&second};
    const slice_state = pipe(&slices, .{hold(@as([]const u32, &first))});
    const length = pipe(&slice_state, .{map(Helpers.length)});
    var a: Saved(u32) = .{};
    var b: Saved(usize) = .{};
    try run(allocator, io, .{
        pipe(values(&total), .{collectThenWith(&a, Saved(u32).copy)}),
        pipe(values(&length), .{collectThenWith(&b, Saved(usize).copy)}),
    });
    try std.testing.expectEqualSlices(u32, &.{ 1, 7, 11 }, a.slice());
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, b.slice());
}

test "sampling retains nested tuple payloads and bare error-set state as data" {
    const Event = @Tuple(&.{ u8, bool });
    const Errors = error{ Initial, Update };
    const updates = [_]Errors{};
    const current = pipe(&updates, .{hold(error.Initial)});
    const events = [_]Event{.{ 1, true }};
    const Pair = @Tuple(&.{ Event, Errors });
    var saved: Saved(Pair) = .{};
    try run(allocator, io, .{pipe(&events, .{
        withLatestFrom(&current),
        collectThenWith(&saved, Saved(Pair).copy),
    })});
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expectEqual(events[0], saved.data[0][0]);
    try std.testing.expectEqual(error.Initial, saved.data[0][1]);
}

test "a final derived cache remains sampleable after update and observation completion" {
    const State = struct {
        observed_end: std.Io.Event = .unset,
        samples: Saved(@Tuple(&.{ u8, i32 })) = .{},
    };
    const Helpers = struct {
        fn double(value: i32) i32 {
            return value * 2;
        }
        fn observed(state: *State, data: []const i32) !void {
            try std.testing.expectEqualSlices(i32, &.{ 20, 23, 18 }, data);
            state.observed_end.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.observed_end.wait(output.io);
            try output.push(1);
            try output.push(2);
        }
    };
    var state: State = .{};
    const updates = [_]i32{ 23, 18 };
    const current = pipe(&updates, .{hold(20)});
    const doubled = pipe(&current, .{map(Helpers.double)});
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const Pair = @Tuple(&.{ u8, i32 });
    try run(allocator, io, .{
        pipe(values(&current), .{collectThenWith(&state, Helpers.observed)}),
        pipe(&requests, .{ withLatestFrom(&doubled), collectThenWith(&state.samples, Saved(Pair).copy) }),
    });
    try std.testing.expectEqual(@as(usize, 2), state.samples.len);
    for (state.samples.slice()) |sample| try std.testing.expectEqual(@as(i32, 36), sample[1]);
}

test "derived computation and blocked publication do not hold the snapshot lock" {
    const Pair = @Tuple(&.{ @Tuple(&.{ u8, i32 }), i32 });
    const State = struct {
        computing: std.Io.Event = .unset,
        finish_compute: std.Io.Event = .unset,
        committed: std.Io.Event = .unset,
        samples: Saved(Pair) = .{},
    };
    const Helpers = struct {
        var control: *State = undefined;
        fn slow(value: i32) i32 {
            // Test instrumentation only: application signal maps must be pure.
            if (value == 1) {
                control.computing.set(io);
                control.finish_compute.wait(io) catch return -1;
            }
            return value * 10;
        }
        fn observe(state: *State, value: i32) void {
            if (value == 10) state.committed.set(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.computing.wait(output.io);
            try output.push(0);
            try state.committed.wait(output.io);
            try output.push(1);
        }
        fn answer(state: *State, sample: Pair) !void {
            try state.samples.append(sample);
            if (sample[0][0] == 0) {
                try std.testing.expectEqual(@as(i32, 0), sample[0][1]);
                try std.testing.expectEqual(@as(i32, 0), sample[1]);
                state.finish_compute.set(io);
            } else {
                try std.testing.expectEqual(@as(i32, 1), sample[0][1]);
                try std.testing.expectEqual(@as(i32, 10), sample[1]);
            }
        }
    };
    var state: State = .{};
    Helpers.control = &state;
    const updates = [_]i32{1};
    const current = pipe(&updates, .{hold(0)});
    const derived = pipe(&current, .{map(Helpers.slow)});
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    try run(allocator, io, .{
        pipe(values(&derived), .{forEachWith(&state, Helpers.observe)}),
        pipe(&requests, .{ withLatestFrom(&current), withLatestFrom(&derived), forEachWith(&state, Helpers.answer) }),
    });
    try std.testing.expectEqual(@as(usize, 2), state.samples.len);
}

test "sampling continues while an observer blocks and publication backpressures updates" {
    const State = struct {
        observer_entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        accepted: std.atomic.Value(usize) = .init(0),
        observer_finished: std.atomic.Value(bool) = .init(false),
        source_finished: std.atomic.Value(bool) = .init(false),
        sampled: bool = false,
    };
    const Helpers = struct {
        fn updates(state: *State, output: *Emitter(i32)) !void {
            defer state.source_finished.store(true, .release);
            var number: i32 = 1;
            while (true) : (number += 1) {
                try output.push(number);
                _ = state.accepted.fetchAdd(1, .monotonic);
            }
        }
        fn observe(state: *State, _: i32) !void {
            defer state.observer_finished.store(true, .release);
            state.observer_entered.set(io);
            try state.gate.wait(io);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.observer_entered.wait(output.io);
            while (true) try output.push(0);
        }
        fn answer(state: *State, sample: @Tuple(&.{ u8, i32 })) !void {
            if (sample[1] == 2) {
                state.sampled = true;
                return error.Done;
            }
        }
    };
    var state: State = .{};
    const updates = Stream(i32).fromProducerWith(1, Helpers.updates, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&updates, .{hold(0)});
    try std.testing.expectError(error.Done, run(allocator, io, .{
        pipe(values(&current), .{forEachWith(&state, Helpers.observe)}),
        pipe(&requests, .{ withLatestFrom(&current), forEachWith(&state, Helpers.answer) }),
    }));
    try std.testing.expect(state.sampled);
    try std.testing.expect(state.accepted.load(.monotonic) <= 3);
    try std.testing.expect(state.observer_finished.load(.acquire));
    try std.testing.expect(state.source_finished.load(.acquire));
}

test "background update errors terminate an idle sampler and preserve source Closed errors" {
    const State = struct {
        request_started: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        request_finished: std.atomic.Value(bool) = .init(false),
        failure: anyerror,
    };
    const Helpers = struct {
        fn updates(state: *State, _: *Emitter(i32)) !void {
            try state.request_started.wait(io);
            return state.failure;
        }
        fn requests(state: *State, _: *Emitter(u8)) !void {
            defer state.request_finished.store(true, .release);
            state.request_started.set(io);
            try state.gate.wait(io);
        }
    };
    const Pair = @Tuple(&.{ u8, i32 });
    for ([_]anyerror{ error.Broken, error.Closed }) |failure| {
        var state: State = .{ .failure = failure };
        const updates = Stream(i32).fromProducerWith(1, Helpers.updates, &state);
        const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
        const current = pipe(&updates, .{hold(20)});
        var saved: Saved(Pair) = .{};
        try std.testing.expectError(failure, run(allocator, io, .{pipe(&requests, .{
            withLatestFrom(&current),
            collectThenWith(&saved, Saved(Pair).copy),
        })}));
        try std.testing.expectEqual(@as(usize, 0), saved.calls);
        try std.testing.expect(state.request_finished.load(.acquire));
    }
}

test "successful event completion cancels an unending state dependency without turning shutdown into failure" {
    const State = struct {
        started: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn updates(state: *State, output: *Emitter(i32)) !void {
            defer state.finished.store(true, .release);
            state.started.set(io);
            while (true) try output.push(1);
        }
        fn requests(state: *State, output: *Emitter(u8)) !void {
            try state.started.wait(io);
            try output.push(1);
        }
    };
    var state: State = .{};
    const updates = Stream(i32).fromProducerWith(1, Helpers.updates, &state);
    const requests = Stream(u8).fromProducerWith(1, Helpers.requests, &state);
    const current = pipe(&updates, .{hold(0)});
    const Pair = @Tuple(&.{ u8, i32 });
    var saved: Saved(Pair) = .{};
    try run(allocator, io, .{pipe(&requests, .{
        withLatestFrom(&current),
        collectThenWith(&saved, Saved(Pair).copy),
    })});
    try std.testing.expectEqual(@as(usize, 1), saved.len);
    try std.testing.expect(state.finished.load(.acquire));
}

test "initial snapshots participate in batch terminals" {
    const Recorder = struct {
        sizes: [3]usize = undefined,
        batches: usize = 0,
        fn batch(self: *@This(), data: []const i32) void {
            self.sizes[self.batches] = data.len;
            self.batches += 1;
        }
    };
    const updates = [_]i32{ 21, 22, 23, 24 };
    const current = pipe(&updates, .{hold(20)});
    var recorder: Recorder = .{};
    try run(allocator, io, .{pipe(values(&current), .{batchThenWith(2, &recorder, Recorder.batch)})});
    try std.testing.expectEqual(@as(usize, 3), recorder.batches);
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 1 }, &recorder.sizes);
}

test "separate state roots over a shared update source retain distinct initials and one producer" {
    const Helpers = struct {
        fn produce(calls: *std.atomic.Value(usize), output: *Emitter(i32)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(23);
            try output.push(18);
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(i32).fromProducerWith(1, Helpers.produce, &calls);
    const first = pipe(&source, .{hold(20)});
    const second = pipe(&source, .{hold(10)});
    var a: Saved(i32) = .{};
    var b: Saved(i32) = .{};
    try run(allocator, io, .{
        pipe(values(&first), .{collectThenWith(&a, Saved(i32).copy)}),
        pipe(values(&second), .{collectThenWith(&b, Saved(i32).copy)}),
    });
    try std.testing.expectEqualSlices(i32, &.{ 20, 23, 18 }, a.slice());
    try std.testing.expectEqualSlices(i32, &.{ 10, 23, 18 }, b.slice());
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
}

test "parent cancellation joins idle update and request producers before disposing caches" {
    const State = struct {
        started: std.atomic.Value(usize) = .init(0),
        finished: std.atomic.Value(usize) = .init(0),
        both_started: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
    };
    const Helpers = struct {
        fn wait(state: *State) !void {
            defer _ = state.finished.fetchAdd(1, .acq_rel);
            if (state.started.fetchAdd(1, .acq_rel) == 1) state.both_started.set(io);
            try state.gate.wait(io);
        }
        fn updates(state: *State, _: *Emitter(i32)) !void {
            try wait(state);
        }
        fn requests(state: *State, _: *Emitter(u8)) !void {
            try wait(state);
        }
        fn execute(state: *State) !void {
            const source = Stream(i32).fromProducerWith(1, updates, state);
            const event_source = Stream(u8).fromProducerWith(1, requests, state);
            const current = pipe(&source, .{hold(20)});
            const Pair = @Tuple(&.{ u8, i32 });
            var saved: Saved(Pair) = .{};
            try run(allocator, io, .{pipe(&event_source, .{
                withLatestFrom(&current),
                collectThenWith(&saved, Saved(Pair).copy),
            })});
        }
    };
    var state: State = .{};
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.both_started.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expectEqual(@as(usize, 2), state.finished.load(.acquire));
}

test "state worker startup failure cleans cold families without initial map or producer callbacks" {
    const Helpers = struct {
        var maps: std.atomic.Value(usize) = .init(0);
        fn produce(calls: *std.atomic.Value(usize), output: *Emitter(i32)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(1);
        }
        fn addOne(value: i32) i32 {
            _ = maps.fetchAdd(1, .monotonic);
            return value + 1;
        }
    };
    Helpers.maps.store(0, .monotonic);
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(3) });
    defer backend.deinit();
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(i32).fromProducerWith(1, Helpers.produce, &calls);
    const first = pipe(&source, .{hold(10)});
    const second = pipe(&source, .{hold(20)});
    const mapped_a = pipe(&first, .{map(Helpers.addOne)});
    const mapped_b = pipe(&second, .{map(Helpers.addOne)});
    var a: Saved(i32) = .{};
    var b: Saved(i32) = .{};
    const flows = .{
        pipe(values(&mapped_a), .{collectThenWith(&a, Saved(i32).copy)}),
        pipe(values(&mapped_b), .{collectThenWith(&b, Saved(i32).copy)}),
    };
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, backend.io(), flows));
    try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), Helpers.maps.load(.monotonic));
    try run(allocator, io, flows);
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4), Helpers.maps.load(.monotonic));
    try std.testing.expectEqualSlices(i32, &.{ 11, 2 }, a.slice());
    try std.testing.expectEqualSlices(i32, &.{ 21, 2 }, b.slice());
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const Helpers = struct {
        fn produce(calls: *std.atomic.Value(usize), output: *Emitter(i32)) !void {
            _ = calls.fetchAdd(1, .monotonic);
            try output.push(23);
            try output.push(18);
        }
        fn double(value: i32) i64 {
            return @as(i64, value) * 2;
        }
    };
    var calls: std.atomic.Value(usize) = .init(0);
    const source = Stream(i32).fromProducerWith(1, Helpers.produce, &calls);
    const current = pipe(&source, .{hold(20)});
    const doubled = pipe(&current, .{map(Helpers.double)});
    const events = [_]u8{ 1, 2 };
    const Pair = @Tuple(&.{ u8, i64 });
    var observed: Saved(i32) = .{};
    var sampled: Saved(Pair) = .{};
    run(gpa, io, .{
        pipe(values(&current), .{forEachWith(&observed, Saved(i32).append)}),
        pipe(&events, .{ withLatestFrom(&doubled), forEachWith(&sampled, Saved(Pair).append) }),
    }) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expectEqual(@as(usize, 0), calls.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 0), observed.len);
            try std.testing.expectEqual(@as(usize, 0), sampled.len);
        }
        return err;
    };
    try std.testing.expectEqualSlices(i32, &.{ 20, 23, 18 }, observed.slice());
    try std.testing.expectEqual(@as(usize, 2), sampled.len);
    try std.testing.expectEqual(@as(usize, 1), calls.load(.monotonic));
}

test "all signal preparation allocation failures release caches families observations and samplers" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}
