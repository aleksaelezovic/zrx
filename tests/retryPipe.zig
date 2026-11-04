const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const retryPipe = zrx.retryPipe;
const map = zrx.map;
const tap = zrx.tap;
const forEach = zrx.forEach;
const run = zrx.run;
const allocator = std.testing.allocator;
const io = std.testing.io;
const E = error{ Transient, Permanent, Canceled };

const State = struct {
    attempts: [3]usize = @splat(0),
    policy_counts: [16]usize = undefined,
    policy_calls: usize = 0,
    values: [8]E!u32 = undefined,
    len: usize = 0,
    taps: usize = 0,
};
fn flaky(state: *State, item: u32) E!u32 {
    state.attempts[item] += 1;
    if (item == 0) return error.Permanent;
    if (item == 1 and state.attempts[item] < 3) return error.Transient;
    return item + 10;
}
fn save(state: *State, value: u32) void {
    state.values[state.len] = switch (value) {
        100 => error.Permanent,
        101 => error.Transient,
        else => value,
    };
    state.len += 1;
}
fn replacement(err: E) u32 {
    return if (err == error.Permanent) 100 else 101;
}
fn policy(state: *State, err: E, retries: usize) zrx.RetryDecision {
    state.policy_counts[state.policy_calls] = retries;
    state.policy_calls += 1;
    if (err == error.Permanent or retries >= 2) return .stop;
    return .{ .retry_after_ms = 0 };
}
fn visited(state: *State, _: u32) void {
    state.taps += 1;
}
fn observedOutcome(state: *State, _: u32) void {
    state.taps += 1;
}

test "fixed retry options are cold and restart from the original item" {
    var state: State = .{};
    const options: zrx.RetryOptions = .{ .max_attempts = 3 };
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{ tap(visited), map(flaky) }, options);
    try std.testing.expectEqual(@as(usize, 0), state.taps);
    try run(.{ allocator, io, &state }, .{pipe(&retried, .{forEach(save)})});
    try std.testing.expectEqual(@as(u32, 11), try state.values[0]);
    try std.testing.expectEqual(@as(usize, 3), state.attempts[1]);
    try std.testing.expectEqual(@as(usize, 3), state.taps);
}

test "typed function policy receives injected services error and zero based retry count" {
    var state: State = .{};
    const retried = retryPipe(zrx.fromSlice(&[_]u32{ 0, 1, 2 }), .{map(flaky)}, policy);
    try run(.{ allocator, io, &state, @as(usize, 999) }, .{pipe(&retried, .{ zrx.recover(replacement), forEach(save) })});
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 1 }, &state.attempts);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1 }, state.policy_counts[0..state.policy_calls]);
    try std.testing.expectError(error.Permanent, state.values[0]);
    try std.testing.expectEqual(@as(u32, 11), try state.values[1]);
    try std.testing.expectEqual(@as(u32, 12), try state.values[2]);
}

test "exhausted retries remain pending until explicit recovery and following items continue" {
    var state: State = .{};
    const retried = retryPipe(zrx.fromSlice(&[_]u32{ 0, 1, 2 }), .{map(flaky)}, .{ .max_attempts = 2 });
    try run(.{ allocator, io, &state }, .{pipe(&retried, .{ zrx.recover(replacement), forEach(save) })});
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 1 }, &state.attempts);
    try std.testing.expectError(error.Permanent, state.values[0]);
    try std.testing.expectError(error.Transient, state.values[1]);
    try std.testing.expectEqual(@as(u32, 12), try state.values[2]);
}

const SleepProbe = struct {
    // Only these sequential finite tests use this shim. Other Io callbacks keep
    // the real backend userdata; this is not a production ambient service.
    var active: *@This() = undefined;
    delays: [4]i96 = undefined,
    len: usize = 0,
    cancel: bool = false,
    fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const duration = timeout.duration;
        std.debug.assert(duration.clock == .awake);
        active.delays[active.len] = duration.raw.nanoseconds;
        active.len += 1;
        if (active.cancel) return error.Canceled;
    }
};
fn delayed(state: *State, err: E, retries: usize) zrx.RetryDecision {
    const decision = policy(state, err, retries);
    return switch (decision) {
        .stop => .stop,
        .retry_after_ms => .{ .retry_after_ms = 7 },
    };
}
test "fixed and function policies wait through run Io with the same attempts and delays" {
    var table = io.vtable.*;
    table.sleep = SleepProbe.sleep;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    inline for (.{ false, true }) |function| {
        var state: State = .{};
        var sleeps: SleepProbe = .{};
        SleepProbe.active = &sleeps;
        const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(flaky)}, if (function) delayed else zrx.RetryOptions{ .max_attempts = 3, .delay_ms = 7 });
        try run(.{ allocator, observed, &state }, .{pipe(&retried, .{forEach(save)})});
        try std.testing.expectEqual(@as(usize, 3), state.attempts[1]);
        try std.testing.expectEqualSlices(i96, &.{ 7_000_000, 7_000_000 }, sleeps.delays[0..sleeps.len]);
        try std.testing.expectEqual(@as(u32, 11), try state.values[0]);
    }
}

test "full u64 delays convert without narrowing overflow" {
    var table = io.vtable.*;
    table.sleep = SleepProbe.sleep;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var state: State = .{};
    var sleeps: SleepProbe = .{};
    SleepProbe.active = &sleeps;
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(flaky)}, .{ .max_attempts = 3, .delay_ms = std.math.maxInt(u64) });
    try run(.{ allocator, observed, &state }, .{pipe(&retried, .{forEach(save)})});
    const delay: i96 = @as(i96, std.math.maxInt(u64)) * std.time.ns_per_ms;
    try std.testing.expectEqualSlices(i96, &.{ delay, delay }, sleeps.delays[0..sleeps.len]);
}

test "cancellation during a delay aborts without another attempt or error item" {
    var table = io.vtable.*;
    table.sleep = SleepProbe.sleep;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var state: State = .{};
    var sleeps: SleepProbe = .{ .cancel = true };
    SleepProbe.active = &sleeps;
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(flaky)}, delayed);
    try std.testing.expectError(error.Canceled, run(.{ allocator, observed, &state }, .{pipe(&retried, .{forEach(save)})}));
    try std.testing.expectEqual(@as(usize, 1), state.attempts[1]);
    try std.testing.expectEqual(@as(usize, 1), state.policy_calls);
    try std.testing.expectEqual(@as(usize, 0), state.len);
}
fn canceled(state: *State, item: u32) E!u32 {
    state.attempts[item] += 1;
    return error.Canceled;
}
test "callback cancellation never reaches the policy" {
    var state: State = .{};
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(canceled)}, policy);
    try std.testing.expectError(error.Canceled, run(.{ allocator, io, &state }, .{pipe(&retried, .{forEach(save)})}));
    try std.testing.expectEqual(@as(usize, 1), state.attempts[1]);
    try std.testing.expectEqual(@as(usize, 0), state.policy_calls);
    try std.testing.expectEqual(@as(usize, 0), state.len);
}

const Lifetime = struct { opened: usize = 0, released: usize = 0, state: State = .{} };
const Owned = struct { lifetime: *Lifetime };
fn acquire(lifetime: *Lifetime, _: void) Owned {
    lifetime.opened += 1;
    return .{ .lifetime = lifetime };
}
fn release(owned: Owned) void {
    owned.lifetime.released += 1;
}
fn useOwned(owned: Owned, item: u32) E!u32 {
    std.debug.assert(owned.lifetime.opened == 1 and owned.lifetime.released == 0);
    return flaky(&owned.lifetime.state, item);
}
fn discard(_: u32) void {}
test "managed attempt dependencies acquire once and release after all retries" {
    var lifetime: Lifetime = .{};
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(useOwned)}, .{ .max_attempts = 3 });
    try run(.{ allocator, io, &lifetime, zrx.resource({}, acquire, release) }, .{pipe(&retried, .{forEach(discard)})});
    try std.testing.expectEqual(@as(usize, 1), lifetime.opened);
    try std.testing.expectEqual(@as(usize, 1), lifetime.released);
    try std.testing.expectEqual(@as(usize, 3), lifetime.state.attempts[1]);
}

fn always(_: u32) bool {
    return true;
}
const InvalidRetry = struct {
    pub fn Output(comptime Source: type) type {
        return @TypeOf(retryPipe(@as(Source, undefined), .{map(useOwned)}, .{ .max_attempts = 0 }));
    }
    pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
        return retryPipe(source, .{map(useOwned)}, .{ .max_attempts = 0 });
    }
};
test "zero attempts fail before acquisition even behind take zero or a case helper" {
    var lifetime: Lifetime = .{};
    const invalid = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(useOwned)}, .{ .max_attempts = 0 });
    const bindings = .{ allocator, io, &lifetime, zrx.resource({}, acquire, release) };
    try std.testing.expectError(error.InvalidRetryAttempts, run(bindings, .{
        pipe(&invalid, .{ zrx.take(0), forEach(discard) }),
    }));
    try std.testing.expectError(error.InvalidRetryAttempts, run(bindings, .{
        pipe(zrx.fromValue(@as(u32, 1)), .{zrx.branch(.{zrx.when(always, .{ InvalidRetry{}, forEach(discard) })})}),
    }));
    try std.testing.expectEqual(@as(usize, 0), lifetime.opened);
    try std.testing.expectEqual(@as(usize, 0), lifetime.released);
}

const Saved = struct { value: ?u32 = null };
const Left = struct { saved: *Saved };
const Right = struct { saved: *Saved };
fn saveLeft(output: Left, value: u32) void {
    output.saved.value = value;
}
fn saveRight(output: Right, value: u32) void {
    output.saved.value = value;
}
test "stable references share the entire retry recurrence and its final result" {
    var state: State = .{};
    var left: Saved = .{};
    var right: Saved = .{};
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(flaky)}, .{ .max_attempts = 3 });
    try run(.{ allocator, io, &state, Left{ .saved = &left }, Right{ .saved = &right } }, .{
        pipe(&retried, .{forEach(saveLeft)}), pipe(&retried, .{forEach(saveRight)}),
    });
    try std.testing.expectEqual(@as(?u32, 11), left.value);
    try std.testing.expectEqual(left.value, right.value);
    try std.testing.expectEqual(@as(usize, 3), state.attempts[1]);
}

const Cursor = struct {
    probes: usize = 0,
    pub fn next(self: *@This()) ?u32 {
        self.probes += 1;
        return 1;
    }
};
test "retries never re-probe a consuming source and take does not probe ahead" {
    var cursor: Cursor = .{};
    var state: State = .{};
    const retried = retryPipe(zrx.fromIterator(&cursor), .{map(flaky)}, .{ .max_attempts = null });
    try run(.{ allocator, io, &state }, .{pipe(&retried, .{ zrx.take(1), forEach(save) })});
    try std.testing.expectEqual(@as(usize, 1), cursor.probes);
    try std.testing.expectEqual(@as(usize, 3), state.attempts[1]);
}

fn broken(_: *zrx.Emitter(u32)) error{SourceFailed}!void {
    return error.SourceFailed;
}
fn reject(_: u32) error{DownstreamFailed}!void {
    return error.DownstreamFailed;
}
test "source and downstream errors stay outside the retry boundary" {
    var state: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, broken);
    try std.testing.expectError(error.SourceFailed, run(.{ allocator, io, &state }, .{
        pipe(retryPipe(&source, .{map(flaky)}, policy), .{forEach(save)}),
    }));
    try std.testing.expectEqual(@as(usize, 0), state.policy_calls);
    try std.testing.expectError(error.DownstreamFailed, run(.{ allocator, io, &state }, .{
        pipe(retryPipe(zrx.fromValue(@as(u32, 2)), .{map(flaky)}, policy), .{forEach(reject)}),
    }));
    try std.testing.expectEqual(@as(usize, 1), state.attempts[2]);
    try std.testing.expectEqual(@as(usize, 0), state.policy_calls);
}

test "producer backed retry transports pending errors to recovery and continues" {
    const Producer = struct {
        fn produce(output: *zrx.Emitter(u32)) !void {
            try output.push(0);
            try output.push(2);
        }
    };
    var state: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, Producer.produce);
    const outcomes = retryPipe(&source, .{map(flaky)}, .{ .max_attempts = 1 });
    try run(.{ allocator, io, &state }, .{pipe(&outcomes, .{ zrx.recover(replacement), tap(observedOutcome), forEach(save) })});
    try std.testing.expectEqual(@as(usize, 2), state.len);
    try std.testing.expectEqual(@as(usize, 2), state.taps);
    try std.testing.expectError(error.Permanent, state.values[0]);
    try std.testing.expectEqual(@as(u32, 12), try state.values[1]);
}

test "grouped callbacks preserve type transitions and stop before later stages" {
    const Helpers = struct {
        fn narrow(state: *State, item: u32) E!u16 {
            return @intCast(try flaky(state, item));
        }
        fn widen(item: u16) u32 {
            return @as(u32, item) * 2;
        }
        fn check(value: u32) !void {
            try std.testing.expectEqual(@as(u32, 22), value);
        }
    };
    var state: State = .{};
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{
        map(.{ Helpers.narrow, Helpers.widen }), tap(visited),
    }, .{ .max_attempts = 3 });
    try run(.{ allocator, io, &state }, .{pipe(&retried, .{forEach(Helpers.check)})});
    try std.testing.expectEqual(@as(usize, 1), state.taps);
}

test "zero-delay unlimited retries remain externally cancelable" {
    const Probe = struct { entered: std.Io.Event = .unset, calls: std.atomic.Value(usize) = .init(0) };
    const Helpers = struct {
        fn fail(probe: *Probe, _: u32) error{Transient}!u32 {
            _ = probe.calls.fetchAdd(1, .monotonic);
            probe.entered.set(io);
            return error.Transient;
        }
        fn sink(_: u32) void {
            @panic("unlimited retries must not emit before cancellation");
        }
        fn execute(probe: *Probe) !void {
            const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(fail)}, .{ .max_attempts = null });
            try run(.{ allocator, io, probe }, .{pipe(&retried, .{forEach(sink)})});
        }
    };
    var probe: Probe = .{};
    var task = try io.concurrent(Helpers.execute, .{&probe});
    defer task.cancel(io) catch {};
    try probe.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(probe.calls.load(.acquire) != 0);
}

test "empty and infallible inputs use the same success item type" {
    const Helpers = struct {
        fn identity(item: u32) u32 {
            return item;
        }
        fn check(value: u32) !void {
            try std.testing.expectEqual(@as(u32, 2), value);
        }
    };
    try run(.{ allocator, io }, .{
        pipe(retryPipe(zrx.fromValue(@as(u32, 2)), .{map(Helpers.identity)}, .{ .max_attempts = 1 }), .{forEach(Helpers.check)}),
    });
    var state: State = .{};
    try run(.{ allocator, io, &state }, .{
        pipe(retryPipe(zrx.fromSlice(&[_]u32{}), .{map(flaky)}, policy), .{forEach(save)}),
    });
    try std.testing.expectEqual(@as(usize, 0), state.len);
    try std.testing.expectEqual(@as(usize, 0), state.policy_calls);
}

test "optional input remains data and exhausted errors suppress collection" {
    const Helpers = struct {
        fn unwrap(item: ?u32) error{Missing}!u32 {
            return item orelse error.Missing;
        }
        fn check(_: []const u32) void {
            @panic("unhandled error must suppress collection");
        }
    };
    const outcomes = retryPipe(zrx.fromSlice(&[_]?u32{ null, 2 }), .{map(Helpers.unwrap)}, .{ .max_attempts = 1 });
    try std.testing.expectError(error.Missing, run(.{ allocator, io }, .{pipe(&outcomes, .{zrx.collectThen(Helpers.check)})}));
}

test "managed dependencies release after canceled retry waits" {
    var table = io.vtable.*;
    table.sleep = SleepProbe.sleep;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var lifetime: Lifetime = .{};
    var sleeps: SleepProbe = .{ .cancel = true };
    SleepProbe.active = &sleeps;
    const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(useOwned)}, .{ .max_attempts = 3, .delay_ms = 7 });
    try std.testing.expectError(error.Canceled, run(.{ allocator, observed, &lifetime, zrx.resource({}, acquire, release) }, .{
        pipe(&retried, .{forEach(discard)}),
    }));
    try std.testing.expectEqual(@as(usize, 1), lifetime.opened);
    try std.testing.expectEqual(@as(usize, 1), lifetime.released);
    try std.testing.expectEqual(@as(usize, 1), lifetime.state.attempts[1]);
}

test "actual checkout composition repeats calls without repeating application owned effects" {
    const example = @import("checkout_example");
    const Output = struct { value: ?example.Shipment = null };
    const Helpers = struct {
        fn capture(output: *Output, value: example.Shipment) void {
            output.value = value;
        }
    };
    var store: example.Store = .{};
    var output: Output = .{};
    const outcomes = example.checkout(zrx.fromValue(example.Cart{ .id = 42, .cents = 2500 }));
    const bindings = .{
        allocator,                         io,                                  &output, example.Payments{ .store = &store },
        example.Orders{ .store = &store }, example.Shipping{ .store = &store },
    };
    try std.testing.expectEqual(@as(usize, 0), store.charges);
    try run(bindings, .{pipe(&outcomes, .{forEach(Helpers.capture)})});
    try std.testing.expectEqual(@as(u32, 42), output.value.?.checkout_id);
    try std.testing.expectEqual(@as(usize, 3), store.payment_calls);
    try std.testing.expectEqual(@as(usize, 3), store.order_calls);
    try std.testing.expectEqual(@as(usize, 3), store.shipping_calls);
    try std.testing.expectEqual(@as(usize, 1), store.charges);
    try std.testing.expectEqual(@as(usize, 1), store.orders);
    try std.testing.expectEqual(@as(usize, 1), store.shipments);
    try run(bindings, .{pipe(&outcomes, .{forEach(Helpers.capture)})});
    try std.testing.expectEqual(@as(usize, 1), store.charges);
    try std.testing.expectEqual(@as(usize, 1), store.orders);
    try std.testing.expectEqual(@as(usize, 1), store.shipments);
}

fn one(output: *zrx.Emitter(u32)) !void {
    try output.push(1);
}
test "an exclusive named retry adds no forwarding worker" {
    var backend: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2), .async_limit = .nothing });
    defer backend.deinit();
    var state: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, one);
    const retried = retryPipe(&source, .{map(flaky)}, .{ .max_attempts = 3 });
    try run(.{ allocator, backend.io(), &state }, .{pipe(&retried, .{forEach(save)})});
    try std.testing.expectEqual(@as(u32, 11), try state.values[0]);
}
fn allocated(gpa: std.mem.Allocator) !void {
    var state: State = .{};
    const source = zrx.Stream(u32).fromProducer(1, one);
    const retried = retryPipe(&source, .{map(flaky)}, policy);
    try run(.{ gpa, io, &state }, .{pipe(&retried, .{forEach(save)})});
    try std.testing.expectEqual(@as(u32, 11), try state.values[0]);
}
test "retry graph preparation allocation failures unwind bound policy and source storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocated, .{});
}

test "request scoped HTTP retries fail before listener acquisition" {
    const Helpers = struct {
        fn handle(request: zrx.HttpRequest) error{Unavailable}!zrx.HttpResponse {
            return request.response(.{});
        }
        fn ignore(_: zrx.HttpResponse) void {}
    };
    var ready: zrx.HttpReady = .{};
    const source = zrx.httpRequests(zrx.HttpServerConfig{ .address = .{ .ip4 = .loopback(0) }, .ready = &ready, .connection_budget = 0 });
    const retried = retryPipe(source, .{map(Helpers.handle)}, .{ .max_attempts = 1 });
    try std.testing.expectError(error.UnsupportedHttpComposition, run(.{ allocator, io }, .{pipe(retried, .{forEach(Helpers.ignore)})}));
    try std.testing.expect(!ready.ready.isSet());
}

test "a peer failure cancels an unlimited retry without replacing the chosen error" {
    const Probe = struct { entered: std.Io.Event = .unset, done: std.Io.Event = .unset };
    const Helpers = struct {
        fn fail(probe: *Probe, _: u32) error{Again}!u32 {
            probe.entered.set(io);
            return error.Again;
        }
        fn peer(probe: *Probe, _: *zrx.Emitter(u32)) !void {
            try probe.entered.wait(io);
            return error.PeerFailed;
        }
        fn ignoreOutcome(_: u32) void {}
        fn ignore(_: u32) void {}
        fn execute(probe: *Probe) !void {
            defer probe.done.set(io);
            const retried = retryPipe(zrx.fromValue(@as(u32, 1)), .{map(fail)}, .{ .max_attempts = null });
            const source = zrx.Stream(u32).fromProducer(1, peer);
            try run(.{ allocator, io, probe }, .{
                pipe(&retried, .{forEach(ignoreOutcome)}),
                pipe(&source, .{forEach(ignore)}),
            });
        }
    };
    var probe: Probe = .{};
    var task = try io.concurrent(Helpers.execute, .{&probe});
    defer task.cancel(io) catch {};
    try probe.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectError(error.PeerFailed, task.await(io));
}
