//! Separate instrumented passes over the same bounded benchmark workloads.
//! Phase checkpoints use a private typed facade; no public hooks or counters.
const std = @import("std");
const builtin = @import("builtin");
const workloads = @import("workloads");
const Meter = @import("meter");
const Spans = @import("spans");
const Phases = @import("phases");
const api = @import("api");
const legacy = api.legacy;
const current = api.current;
const Shape = workloads.Shape;
const Variant = workloads.Variant;
const Mode = enum { allocations, activity, phases };
const legacyPipe = legacy.pipe;
const legacyEach = legacy.each;
const legacyFilter = legacy.filter;
const legacyForEach = legacy.forEachWith;
const legacyRun = legacy.run;
const pipe = current.pipe;
const each = current.each;
const filter = current.filter;
const forEach = current.forEach;
const run = current.run;

const PhaseProducer = struct { work: workloads.Producer, trace: *Spans };
const Left = struct { sink: *workloads.Sink, trace: *Spans, expected: usize };
const Right = struct { sink: *workloads.Sink, trace: *Spans, expected: usize };
fn produce(state: *PhaseProducer, output: *current.Emitter(workloads.Packet)) !void {
    state.trace.sourceEnter();
    defer state.trace.sourceExit();
    try workloads.produce(&state.work, output);
}
fn acceptLeft(output: Left, value: u64) void {
    // Each sink is serial. Observe only its first entry and final exit rather
    // than serializing/clocking every item across otherwise independent roots.
    if (output.sink.count == 0) output.trace.sinkEnter();
    output.sink.accept(value);
    if (output.sink.count == output.expected) output.trace.sinkExit();
}
fn acceptRight(output: Right, value: u64) void {
    if (output.sink.count == 0) output.trace.sinkEnter();
    output.sink.accept(value);
    if (output.sink.count == output.expected) output.trace.sinkExit();
}
fn legacyLeft(output: *Left, value: u64) void {
    acceptLeft(output.*, value);
}
fn legacyRight(output: *Right, value: u64) void {
    acceptRight(output.*, value);
}

fn executeActivity(comptime shape: Shape, comptime variant: Variant, allocator: std.mem.Allocator, io: std.Io, items: usize, capacity: usize, trace: *Spans) !workloads.Result {
    var state: PhaseProducer = .{ .work = .{ .items = items }, .trace = trace };
    var left: workloads.Sink = .{};
    var right: workloads.Sink = .{};
    var left_context: Left = .{ .sink = &left, .trace = trace, .expected = items / 2 };
    var right_context: Right = .{ .sink = &right, .trace = trace, .expected = items };
    if (variant == .graph) {
        const source = legacy.Stream(workloads.Packet).fromProducerWith(capacity, produce, &state);
        const mixed = legacyPipe(&source, .{legacyEach(workloads.mix)});
        const left_flow = legacyPipe(&mixed, .{
            legacyFilter(workloads.keepEven), legacyEach(workloads.finish), legacyForEach(&left_context, legacyLeft),
        });
        if (shape == .linear) {
            try legacyRun(allocator, io, .{left_flow});
        } else {
            const right_flow = legacyPipe(&mixed, .{ legacyEach(workloads.otherFinish), legacyForEach(&right_context, legacyRight) });
            try legacyRun(allocator, io, .{ left_flow, right_flow });
        }
    } else if (variant == .current) {
        const source = current.Stream(workloads.Packet).fromProducer(capacity, produce);
        const mixed = pipe(&source, .{each(workloads.mix)});
        const left_flow = pipe(&mixed, .{ filter(workloads.keepEven), each(workloads.finish), forEach(acceptLeft) });
        const bindings = .{ allocator, io, &state, left_context, right_context };
        if (shape == .linear) {
            try run(bindings, .{left_flow});
        } else {
            const right_flow = pipe(&mixed, .{ each(workloads.otherFinish), forEach(acceptRight) });
            try run(bindings, .{ left_flow, right_flow });
        }
    } else @compileError("activity checkpoints are defined only for graph variants");
    return .{
        .calls = state.work.calls,
        .produced = state.work.produced,
        .evaluations = state.work.evaluations,
        .left = left,
        .right = right,
    };
}

fn allocations(comptime shape: Shape, comptime variant: Variant, backing: std.mem.Allocator, io: std.Io, items: usize, capacity: usize, trial: usize, expected: workloads.Result) !void {
    var meter: Meter = .init(backing, io);
    const result = workloads.execute(shape, variant, meter.allocator(), io, items, capacity);
    const stats = meter.snapshot(); // execute returned after all run users joined.
    const total = try std.math.add(usize, stats.fresh_bytes, stats.growth_bytes);
    if (!stats.clean() or stats.alloc_successes != stats.free_calls or
        total != stats.released_bytes)
        return error.UnbalancedAllocationAccounting;
    const actual = try result;
    try workloads.verify(shape, items, expected, actual);
    std.debug.print("{s},{s},{d}", .{ @tagName(shape), @tagName(variant), trial });
    inline for (@typeInfo(Meter.Stats).@"struct".field_names) |name|
        std.debug.print(",{d}", .{@field(stats, name)});
    std.debug.print(",{d},{d},{d},{d},{x},{d},{x}\n", .{
        actual.calls,      actual.produced,  actual.evaluations,
        actual.left.count, actual.left.hash, actual.right.count,
        actual.right.hash,
    });
}
fn maybe(value: ?u64) void {
    if (value) |ns| std.debug.print("{d}", .{ns}) else std.debug.print("NA", .{});
}
fn activity(comptime shape: Shape, comptime variant: Variant, backing: std.mem.Allocator, io: std.Io, items: usize, capacity: usize, trial: usize, expected: workloads.Result) !void {
    var trace: Spans = .init(io);
    const result = try executeActivity(shape, variant, backing, io, items, capacity, &trace);
    const sample = try trace.finish();
    try workloads.verify(shape, items, expected, result);
    const nonempty_sinks = @as(usize, @intFromBool(result.left.count != 0)) + @intFromBool(result.right.count != 0);
    if (sample.sink_entries != nonempty_sinks)
        return error.IncorrectCallbackCount;
    std.debug.print("{s},{s},{d},{d},{d},{d},{d},{d},", .{
        @tagName(shape),              @tagName(variant),       trial,               sample.elapsed_ns,
        sample.first_source_entry_ns, sample.callbackWindow(), sample.returnTail(), sample.producer_exit_ns,
    });
    maybe(sample.first_sink_entry_ns);
    std.debug.print(",", .{});
    maybe(sample.last_sink_exit_ns);
    std.debug.print(",{d},{d}\n", .{ sample.sink_entries, sample.sink_exits });
}

fn phases(comptime shape: Shape, comptime variant: Variant, backing: std.mem.Allocator, io: std.Io, items: usize, capacity: usize, trial: usize, expected: workloads.Result) !void {
    var trace: Phases = .init(io);
    const result = try workloads.executeObserved(shape, variant, backing, io, items, capacity, &trace);
    const sample = try trace.finish();
    try workloads.verify(shape, items, expected, result);
    std.debug.print("{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
        @tagName(shape),       @tagName(variant),          trial,            sample.elapsed_ns,
        sample.preparation_ns, sample.acquisition_init_ns, sample.active_ns, sample.return_cleanup_ns,
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.ExpectedModeItemsWarmupsTrialsCapacity;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidMeasurementMode;
    const items = try std.fmt.parseInt(usize, args[2], 10);
    const warmups = try std.fmt.parseInt(usize, args[3], 10);
    const trials = try std.fmt.parseInt(usize, args[4], 10);
    const capacity = try std.fmt.parseInt(usize, args[5], 10);
    if (warmups == 0 or trials == 0 or capacity == 0) return error.ExpectedPositiveOptions;
    const backing = std.heap.smp_allocator;
    // Neither this backend nor its bookkeeping allocates through the meter.
    var backend: std.Io.Threaded = .init(backing, .{ .async_limit = .nothing, .concurrent_limit = .unlimited });
    defer backend.deinit();
    const io = backend.io();
    std.debug.print("# mode={s} zig={s} backend={s} optimize={s} arch={s} os={s} abi={s} cpu={s}\n", .{
        @tagName(mode),             builtin.zig_version_string, @tagName(builtin.zig_backend), @tagName(builtin.mode),
        @tagName(builtin.cpu.arch), @tagName(builtin.os.tag),   @tagName(builtin.abi),         builtin.cpu.model.name,
    });
    std.debug.print("# io=Threaded async=nothing concurrent=unlimited backing=smp_allocator items={d} capacity={d} warmups={d} trials={d}\n", .{ items, capacity, warmups, trials });
    if (mode == .allocations) {
        std.debug.print("# scope=run-allocator-only; backend/driver/stacks/RSS/occupied-payload excluded; no timing reported\nshape,variant,trial", .{});
        inline for (@typeInfo(Meter.Stats).@"struct".field_names) |name| std.debug.print(",{s}", .{name});
        std.debug.print(",producer_calls,produced,mix_evaluations,left_count,left_hash,right_count,right_hash\n", .{});
    } else if (mode == .activity) {
        std.debug.print("# first/last checkpoints per nonempty serial sink only; instrumented spans are NOT exact setup/processing/teardown and NOT headline timings\n", .{});
        std.debug.print("shape,variant,trial,elapsed_ns,start_to_first_source_ns,callback_window_ns,last_observed_exit_to_return_ns,producer_exit_ns,first_sink_entry_ns,last_sink_exit_ns,sink_checkpoint_pairs,completed_sink_pairs\n", .{});
    } else {
        std.debug.print("# coordinator checkpoints; result observation includes notification delay; active includes startup/waiting; NOT CPU time or headline timings\n", .{});
        std.debug.print("shape,variant,trial,elapsed_ns,preparation_ns,acquisition_init_ns,active_ns,return_cleanup_ns\n", .{});
    }
    inline for (.{ Shape.linear, Shape.fanout }) |shape| {
        const expected = try workloads.execute(shape, .direct, backing, io, items, capacity);
        for (0..warmups) |_| {
            if (mode == .allocations) {
                inline for (.{ Variant.direct, Variant.graph, Variant.current }) |variant|
                    try workloads.verify(shape, items, expected, try workloads.execute(shape, variant, backing, io, items, capacity));
            } else if (mode == .activity) {
                inline for (.{ Variant.graph, Variant.current }) |variant| {
                    var trace: Spans = .init(io);
                    const result = try executeActivity(shape, variant, backing, io, items, capacity, &trace);
                    _ = try trace.finish();
                    try workloads.verify(shape, items, expected, result);
                }
            } else {
                inline for (.{ Variant.graph, Variant.current }) |variant| {
                    var trace: Phases = .init(io);
                    const result = try workloads.executeObserved(shape, variant, backing, io, items, capacity, &trace);
                    _ = try trace.finish();
                    try workloads.verify(shape, items, expected, result);
                }
            }
        }
        for (0..trials) |trial| {
            if (mode == .allocations) {
                inline for (.{ Variant.direct, Variant.graph, Variant.current }) |variant|
                    try allocations(shape, variant, backing, io, items, capacity, trial, expected);
            } else if (mode == .activity) {
                // Rotate order without adding direct's nonexistent producer checkpoint.
                if (trial % 2 == 0) {
                    try activity(shape, .graph, backing, io, items, capacity, trial, expected);
                    try activity(shape, .current, backing, io, items, capacity, trial, expected);
                } else {
                    try activity(shape, .current, backing, io, items, capacity, trial, expected);
                    try activity(shape, .graph, backing, io, items, capacity, trial, expected);
                }
            } else {
                if (trial % 2 == 0) {
                    try phases(shape, .graph, backing, io, items, capacity, trial, expected);
                    try phases(shape, .current, backing, io, items, capacity, trial, expected);
                } else {
                    try phases(shape, .current, backing, io, items, capacity, trial, expected);
                    try phases(shape, .graph, backing, io, items, capacity, trial, expected);
                }
            }
        }
    }
}
