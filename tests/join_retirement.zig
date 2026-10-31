//! Deterministic private transport schedules, using only a test-local Io shim.
//! The standard backend still owns real futures; no runtime hooks are added.
const std = @import("std");
const runtime = @import("runtime");
const allocator = std.testing.allocator;
const io = std.testing.io;
const Stream = runtime.Stream(u32);
const Schedule = enum { await_first, retirement_first };

const Probe = struct {
    schedule: Schedule,
    fail_source: bool,
    source: *Stream = undefined,
    result_word: *const u32 = undefined,
    join_entered: std.Io.Event = .unset,
    join_proceed: std.Io.Event = .unset,
    reader_blocked: std.Io.Event = .unset,
    reader_proceed: std.Io.Event = .unset,
    reader_waiting: std.Io.Event = .unset,
    retirement_blocked: std.Io.Event = .unset,
    reader_done: std.Io.Event = .unset,
    retirement_done: std.Io.Event = .unset,
    awaits: std.atomic.Value(usize) = .init(0),
    cancels: std.atomic.Value(usize) = .init(0),
    joins_active: std.atomic.Value(usize) = .init(0),
    produced: std.atomic.Value(usize) = .init(0),
};

const Hooks = struct {
    // VTable callbacks cannot capture a context while preserving the real
    // backend userdata. The sequential test owns this pointer until all users
    // join; it is never a production or dependency-injection context.
    var current: *Probe = undefined;

    fn enter() void {
        if (current.joins_active.fetchAdd(1, .acq_rel) != 0)
            @panic("overlapping producer Future joins");
    }
    fn awaitFuture(userdata: ?*anyopaque, future: *std.Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
        enter();
        defer _ = current.joins_active.fetchSub(1, .acq_rel);
        _ = current.awaits.fetchAdd(1, .monotonic);
        current.join_entered.set(io);
        current.join_proceed.waitUncancelable(io);
        io.vtable.await(userdata, future, result, alignment);
    }
    fn cancelFuture(userdata: ?*anyopaque, future: *std.Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
        enter();
        defer _ = current.joins_active.fetchSub(1, .acq_rel);
        _ = current.cancels.fetchAdd(1, .monotonic);
        current.join_entered.set(io);
        current.join_proceed.waitUncancelable(io);
        io.vtable.cancel(userdata, future, result, alignment);
    }
    fn wait(userdata: ?*anyopaque, word: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (word == current.result_word and current.schedule == .retirement_first) {
            // This point proves the reader already passed the cancellable
            // producer-completion wait and is trying to acquire result_mutex.
            current.reader_blocked.set(io);
            current.reader_proceed.waitUncancelable(io);
            current.reader_waiting.set(io);
        }
        return io.vtable.futexWait(userdata, word, expected, timeout);
    }
    fn waitUncancelable(userdata: ?*anyopaque, word: *const u32, expected: u32) void {
        if (word == current.result_word) current.retirement_blocked.set(io);
        io.vtable.futexWaitUncancelable(userdata, word, expected);
    }
};

fn wait(event: *std.Io.Event) !void {
    try event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
}
fn produce(probe: *Probe, _: *Stream) !void {
    _ = probe.produced.fetchAdd(1, .monotonic);
    if (probe.fail_source) return error.Broken;
}
fn retireInputs(_: *anyopaque) void {}
fn unused(raw: *anyopaque) void {
    const probe: *Probe = @ptrCast(@alignCast(raw));
    runtime.stopProducer(probe.source);
}
fn read(probe: *Probe, reader: *Stream.Reader) anyerror!void {
    defer probe.reader_done.set(io);
    var cursor = reader.iterator();
    if (probe.fail_source)
        try std.testing.expectError(error.Broken, cursor.next())
    else
        try std.testing.expectEqual(@as(?u32, null), try cursor.next());
}
fn retire(probe: *Probe, reader: *Stream.Reader) void {
    defer probe.retirement_done.set(io);
    reader.close();
}

fn scenario(schedule: Schedule, fail_source: bool) !void {
    var probe: Probe = .{ .schedule = schedule, .fail_source = fail_source };
    Hooks.current = &probe;
    var table = io.vtable.*;
    table.await = Hooks.awaitFuture;
    table.cancel = Hooks.cancelFuture;
    table.futexWait = Hooks.wait;
    table.futexWaitUncancelable = Hooks.waitUncancelable;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var source = try Stream.fromProducerWith(allocator, observed, 1, produce, &probe);
    defer source.deinit();
    probe.source = &source;
    probe.result_word = @ptrCast(&source.state.result_mutex.state.raw);
    source.setRetirement(&probe, retireInputs, unused);
    var split = try runtime.tee(&source);
    defer split.deinit();
    split.right.close(); // The other reader's close must trigger last-edge stop.

    var reading: ?std.Io.Future(anyerror!void) = null;
    var retiring: ?std.Io.Future(void) = null;
    var held = false;
    defer {
        // Release every artificial gate before cancel/join on a failing test.
        probe.reader_proceed.set(io);
        probe.join_proceed.set(io);
        if (held) source.state.result_mutex.unlock(observed);
        if (retiring) |*task| task.cancel(io);
        if (reading) |*task| task.cancel(io) catch {};
    }

    if (schedule == .retirement_first) {
        source.state.result_mutex.lockUncancelable(observed);
        held = true;
    }
    reading = try io.concurrent(read, .{ &probe, &split.left });
    if (schedule == .await_first) {
        try wait(&probe.join_entered);
        try std.testing.expectEqual(@as(usize, 1), probe.awaits.load(.acquire));
        retiring = try io.concurrent(retire, .{ &probe, &split.left });
        try wait(&probe.retirement_blocked);
        // The exact mutex wait is observed, not guessed from a task-start event.
        try std.testing.expectEqual(@as(usize, 0), probe.cancels.load(.acquire));
    } else {
        try wait(&probe.reader_blocked);
        retiring = try io.concurrent(retire, .{ &probe, &split.left });
        try wait(&probe.retirement_blocked);
        source.state.result_mutex.unlock(observed);
        held = false;
        try wait(&probe.join_entered);
        try std.testing.expectEqual(@as(usize, 1), probe.cancels.load(.acquire));
        probe.reader_proceed.set(io);
        try wait(&probe.reader_waiting);
        try std.testing.expectEqual(@as(usize, 0), probe.awaits.load(.acquire));
    }
    probe.join_proceed.set(io);
    try wait(&probe.reader_done);
    try wait(&probe.retirement_done);
    try reading.?.await(io);
    retiring.?.await(io);

    try std.testing.expectEqual(@as(usize, 1), probe.produced.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), probe.joins_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), probe.awaits.load(.acquire) + probe.cancels.load(.acquire));
    if (source.state.task) |*task| {
        try std.testing.expect(task.any_future == null);
        if (fail_source)
            try std.testing.expectError(error.Broken, task.await(observed))
        else
            try task.await(observed);
    } else return error.ProducerDidNotStart;
    // Cached results must not cause another backend join.
    try std.testing.expectEqual(@as(usize, 1), probe.awaits.load(.acquire) + probe.cancels.load(.acquire));
}

test "producer await wins while last-reader retirement contends on its result mutex" {
    for ([_]bool{ false, true }) |failure| try scenario(.await_first, failure);
}
test "retirement wins while an already-completed reader waits for its cached result" {
    for ([_]bool{ false, true }) |failure| try scenario(.retirement_first, failure);
}
