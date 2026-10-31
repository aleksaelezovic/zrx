const std = @import("std");
const api = @import("api");
const zrx = api.current;
const Phases = @import("phases");
const workloads = @import("workloads");
const io = std.testing.io;
const allocator = std.testing.allocator;

fn partition(sample: Phases.Sample) !void {
    try std.testing.expectEqual(sample.elapsed_ns, sample.preparation_ns +
        sample.acquisition_init_ns + sample.active_ns + sample.return_cleanup_ns);
}

test "phase collector rejects incomplete duplicate and reversed checkpoints" {
    var trace: Phases = .init(io);
    try std.testing.expectError(error.IncompletePhaseTrace, trace.finish());
    trace.mark(.prepared);
    trace.mark(.activation_ready);
    trace.mark(.result_observed);
    try partition(try trace.finish());
    trace.stamps = .{ 2, 1, 3 };
    try std.testing.expectError(error.InvalidPhaseTrace, trace.finish());
    trace.mark(.prepared);
    try std.testing.expectError(error.InvalidPhaseTrace, trace.finish());
    try std.testing.expect(!@hasDecl(zrx, "runObserved"));
}

test "real graph phase samples preserve empty odd and even workload results" {
    inline for (.{ workloads.Shape.linear, workloads.Shape.fanout }) |shape| {
        for ([_]usize{ 0, 1, 32 }) |n| {
            const expected = try workloads.execute(shape, .direct, allocator, io, n, 4);
            inline for (.{ workloads.Variant.graph, workloads.Variant.current }) |variant| {
                var trace: Phases = .init(io);
                const result = try workloads.executeObserved(shape, variant, allocator, io, n, 4, &trace);
                try workloads.verify(shape, n, expected, result);
                try partition(try trace.finish());
            }
        }
    }
}

test "finite and graph checkpoints surround acquisition effects and reverse release" {
    const State = struct {
        trace: *Phases,
        fail_acquire: bool = false,
        fail_effect: bool = false,
        effects: usize = 0,
        released: usize = 0,
        invalid: bool = false,
    };
    const Owned = struct { state: *State };
    const Helpers = struct {
        fn produce(output: *zrx.Emitter(u32)) !void {
            try output.push(1);
            try output.push(2);
        }
        fn acquire(state: *State, _: void) !Owned {
            if (state.trace.stamps[0] == null or state.trace.stamps[1] != null)
                state.invalid = true;
            if (state.fail_acquire) return error.AcquireFailed;
            return .{ .state = state };
        }
        fn effect(owned: Owned, _: u32) !void {
            const state = owned.state;
            if (state.trace.stamps[1] == null or state.trace.stamps[2] != null)
                state.invalid = true;
            state.effects += 1;
            if (state.fail_effect) return error.EffectFailed;
        }
        fn release(owned: Owned) void {
            if (owned.state.trace.stamps[2] == null) owned.state.invalid = true;
            owned.state.released += 1;
        }
    };
    const data = [_]u32{ 1, 2 };
    inline for (0..6) |scenario| {
        const mode = scenario % 3;
        var trace: Phases = .init(io);
        var state: State = .{ .trace = &trace, .fail_acquire = mode == 1, .fail_effect = mode == 2 };
        const source = if (scenario < 3) zrx.fromSlice(&data) else zrx.Stream(u32).fromProducer(1, Helpers.produce);
        const flow = zrx.pipe(source, .{zrx.forEach(Helpers.effect)});
        const result = api.runObserved(.{
            allocator, io, &state, zrx.resource({}, Helpers.acquire, Helpers.release),
        }, .{flow}, &trace);
        if (mode == 1) {
            try std.testing.expectError(error.AcquireFailed, result);
            try std.testing.expectError(error.IncompletePhaseTrace, trace.finish());
            try std.testing.expect(trace.stamps[0] != null and trace.stamps[1] == null and trace.stamps[2] == null);
        } else {
            if (mode == 2) try std.testing.expectError(error.EffectFailed, result) else try result;
            try partition(try trace.finish());
        }
        try std.testing.expect(!state.invalid);
        try std.testing.expectEqual(@as(usize, if (mode == 1) 0 else 1), state.released);
        try std.testing.expectEqual(@as(usize, if (mode == 1) 0 else if (mode == 2) 1 else 2), state.effects);
    }
}

test "graph failure is observed before shutdown and service release follows producer join" {
    const State = struct {
        trace: *Phases,
        gate: std.Io.Event = .unset,
        stopped: std.atomic.Value(bool) = .init(false),
        released: bool = false,
        invalid: bool = false,
    };
    const Owned = struct { state: *State };
    const Helpers = struct {
        fn acquire(state: *State, _: void) Owned {
            if (state.trace.stamps[0] == null or state.trace.stamps[1] != null) state.invalid = true;
            return .{ .state = state };
        }
        fn produce(state: *State, output: *zrx.Emitter(u32)) !void {
            defer state.stopped.store(true, .release);
            try output.push(1);
            try state.gate.wait(output.io);
        }
        fn fail(_: Owned, _: u32) !void {
            return error.CallbackFailed;
        }
        fn release(owned: Owned) void {
            const state = owned.state;
            if (state.trace.stamps[2] == null or !state.stopped.load(.acquire)) state.invalid = true;
            state.released = true;
        }
    };
    var trace: Phases = .init(io);
    var state: State = .{ .trace = &trace };
    const source = zrx.Stream(u32).fromProducer(1, Helpers.produce);
    const flow = zrx.pipe(source, .{zrx.forEach(Helpers.fail)});
    try std.testing.expectError(error.CallbackFailed, api.runObserved(.{
        allocator, io, &state, zrx.resource({}, Helpers.acquire, Helpers.release),
    }, .{flow}, &trace));
    try partition(try trace.finish());
    try std.testing.expect(state.released and !state.invalid);
}

test "external cancellation preserves a complete active-run phase trace" {
    const State = struct {
        trace: *Phases,
        entered: std.Io.Event = .unset,
        gate: std.Io.Event = .unset,
        stopped: std.atomic.Value(bool) = .init(false),
    };
    const Helpers = struct {
        fn produce(state: *State, output: *zrx.Emitter(u32)) !void {
            defer state.stopped.store(true, .release);
            state.entered.set(output.io);
            try state.gate.wait(output.io);
        }
        fn sink(_: u32) void {}
        fn execute(state: *State) !void {
            const source = zrx.Stream(u32).fromProducer(1, produce);
            try api.runObserved(.{ allocator, io, state }, .{zrx.pipe(source, .{zrx.forEach(sink)})}, state.trace);
        }
    };
    var trace: Phases = .init(io);
    var state: State = .{ .trace = &trace };
    var task = try io.concurrent(Helpers.execute, .{&state});
    defer task.cancel(io) catch {};
    try state.entered.wait(io);
    try std.testing.expectError(error.Canceled, task.cancel(io));
    try std.testing.expect(state.stopped.load(.acquire));
    try partition(try trace.finish());
}

fn failedObserved(gpa: std.mem.Allocator) !void {
    var trace: Phases = .init(io);
    const result = workloads.executeObserved(.fanout, .current, gpa, io, 7, 2, &trace);
    _ = try result; // Failure traces may be incomplete; storage must still unwind.
    try partition(try trace.finish());
}
test "observed graph preparation unwinds at every allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, failedObserved, .{});
}

test "cold worker startup has no fabricated checkpoints and active startup failure has an outcome" {
    const Helpers = struct {
        fn produce(calls: *usize, _: *zrx.Emitter(u32)) !void {
            calls.* += 1;
        }
        fn ignore(_: u32) void {}
    };
    for (0..2) |limit| {
        var backend: std.Io.Threaded = .init(allocator, .{
            .async_limit = .nothing,
            .concurrent_limit = .limited(limit),
        });
        defer backend.deinit();
        const backend_io = backend.io();
        var trace: Phases = .init(backend_io);
        var calls: usize = 0;
        const source = zrx.Stream(u32).fromProducer(1, Helpers.produce);
        try std.testing.expectError(error.ConcurrencyUnavailable, api.runObserved(.{ allocator, backend_io, &calls }, .{
            zrx.pipe(source, .{zrx.forEach(Helpers.ignore)}),
        }, &trace));
        if (limit == 0) {
            try std.testing.expectEqualDeep([3]?u64{ null, null, null }, trace.stamps);
            try std.testing.expectError(error.IncompletePhaseTrace, trace.finish());
        } else try partition(try trace.finish());
        try std.testing.expectEqual(@as(usize, 0), calls);
    }
}

test "erasure fixtures execute both finite and producer paths" {
    const fixture = @import("phase_erasure.zig");
    inline for (.{ fixture.finite_default, fixture.finite_empty, fixture.graph_default, fixture.graph_empty }) |execute| {
        var total: u64 = 0;
        try std.testing.expect(execute(&io, 8, &total));
        try std.testing.expectEqual(@as(u64, 92), total);
    }
}
